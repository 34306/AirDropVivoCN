// SPDX-License-Identifier: GPL-2.0
/*
 * Stand-in for the wonder glue that vivo's global PD2547F firmware has and the
 * CN firmware lacks, so the global qca_cld3_peach_v2.ko and wonder.ko can run
 * on the CN kernel. In the global build:
 *
 *  - cnss2.ko binds the DT node qcom,cnss-vendor-wlan-wonder. The Wi-Fi driver
 *    calls cnss_set_vendor_wonder_priv_data() at probe with its wondertap ops;
 *    cnss2 stores them as the device's drvdata and registers a component.
 *  - wonder.ko binds the DT node wonder-device, follows its wondertap-provider
 *    phandle, waits for that component and reads the ops from its drvdata.
 *
 * The CN device tree has neither node and the CN kernel cannot add nodes at
 * run time (no OF_OVERLAY or OF_DYNAMIC). This module creates both devices on
 * existing nodes instead: the provider device on a node that has a phandle and
 * no device, and a device named "wonder" (wonder.ko has no id_table, so the
 * platform bus binds it by name) on a node that gets a wondertap-provider
 * property. Nothing is written to storage; the property lives in RAM only.
 *
 * It also exports no-op vwnld_* functions. wonder.ko uses them to report to
 * vivo's framework through vivo_wifi_driver, but only after vivo userspace has
 * subscribed. The CN vivo_wifi_driver keeps these functions static.
 */
#include <linux/component.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/skbuff.h>
#include <linux/slab.h>

static char *provider_node = "/soc/pinctrl@f000000/cnss_pins/cnss_host_sol_default";
module_param(provider_node, charp, 0444);
MODULE_PARM_DESC(provider_node, "Existing DT node with a phandle and no device, used as the wondertap provider");

static char *wonder_node = "/soc/pinctrl@f000000/cnss_pins";
module_param(wonder_node, charp, 0444);
MODULE_PARM_DESC(wonder_node, "Existing DT node that gets the wondertap-provider property");

/* Offsets used by vivo's wonder.ko and cnss2.ko, which the CN kernel loads with matching CRCs. */
static_assert(offsetof(struct platform_device, dev) == 0x10);
static_assert(offsetof(struct device, driver_data) == 0x98);
static_assert(offsetof(struct device, of_node) == 0x2e8);
static_assert(sizeof(struct module) == 0x640);

#define PROVIDER_PROP "wondertap-provider"

static DEFINE_MUTEX(shim_lock);
static struct platform_device *provider_pdev;
static struct platform_device *wonder_pdev;
static struct device_node *wonder_np;
static struct property *provider_prop;
static bool component_registered;

static int shim_bind(struct device *dev, struct device *master, void *data)
{
	dev_info(dev, "bound to %s\n", dev_name(master));
	return 0;
}

static void shim_unbind(struct device *dev, struct device *master, void *data)
{
	dev_info(dev, "unbound from %s\n", dev_name(master));
}

static const struct component_ops shim_component_ops = {
	.bind = shim_bind,
	.unbind = shim_unbind,
};

/* Behaves like the global cnss2.ko version, which also always returns 0. */
int cnss_set_vendor_wonder_priv_data(void *data)
{
	int ret = 0;

	mutex_lock(&shim_lock);
	if (!provider_pdev) {
		pr_err("wonder_shim: no provider device\n");
		goto out;
	}
	if (component_registered) {
		component_del(&provider_pdev->dev, &shim_component_ops);
		component_registered = false;
	}
	platform_set_drvdata(provider_pdev, data);
	if (data) {
		ret = component_add(&provider_pdev->dev, &shim_component_ops);
		component_registered = !ret;
	}
	dev_info(&provider_pdev->dev, "wondertap ops %s (%d)\n", data ? "set" : "cleared", ret);
out:
	mutex_unlock(&shim_lock);
	return 0;
}
EXPORT_SYMBOL(cnss_set_vendor_wonder_priv_data);

int vwnld_register_msg_handler(int type, void *handler)
{
	pr_info("wonder_shim: vwnld handler for type %d not connected\n", type);
	return 0;
}
EXPORT_SYMBOL(vwnld_register_msg_handler);

int vwnld_unregister_msg_handler(int type)
{
	return 0;
}
EXPORT_SYMBOL(vwnld_unregister_msg_handler);

struct sk_buff *vwnld_msg_new(void *unused, unsigned int len)
{
	return NULL;
}
EXPORT_SYMBOL(vwnld_msg_new);

void *__vwnld_msghdr_put(struct sk_buff *skb, int cmd, int flags, u32 portid, u32 seq, int extra)
{
	return NULL;
}
EXPORT_SYMBOL(__vwnld_msghdr_put);

int vwnld_send_msg(u32 portid, struct sk_buff *skb)
{
	kfree_skb(skb);
	return -ENOTCONN;
}
EXPORT_SYMBOL(vwnld_send_msg);

/* The node keeps the property after this module unloads, so it must not live in module memory. */
static struct property *new_phandle_property(u32 phandle)
{
	struct property *prop = kzalloc(sizeof(*prop), GFP_KERNEL);
	__be32 *value = kmalloc(sizeof(*value), GFP_KERNEL);
	char *name = kstrdup(PROVIDER_PROP, GFP_KERNEL);

	if (!prop || !value || !name) {
		kfree(prop);
		kfree(value);
		kfree(name);
		return NULL;
	}
	*value = cpu_to_be32(phandle);
	prop->name = name;
	prop->value = value;
	prop->length = sizeof(*value);
	return prop;
}

static struct platform_device *add_device(const char *name, struct device_node *np)
{
	struct platform_device *pdev = platform_device_alloc(name, PLATFORM_DEVID_NONE);
	int ret;

	if (!pdev)
		return ERR_PTR(-ENOMEM);
	pdev->dev.of_node = np;
	ret = platform_device_add(pdev);
	if (ret) {
		platform_device_put(pdev);
		return ERR_PTR(ret);
	}
	return pdev;
}

static void remove_devices(void)
{
	if (!IS_ERR_OR_NULL(wonder_pdev))
		platform_device_unregister(wonder_pdev);
	wonder_pdev = NULL;
	mutex_lock(&shim_lock);
	if (component_registered)
		component_del(&provider_pdev->dev, &shim_component_ops);
	component_registered = false;
	if (!IS_ERR_OR_NULL(provider_pdev))
		platform_device_unregister(provider_pdev);
	provider_pdev = NULL;
	mutex_unlock(&shim_lock);
	if (provider_prop)
		of_remove_property(wonder_np, provider_prop);
	provider_prop = NULL;
}

static int __init wonder_shim_init(void)
{
	struct device_node *provider_np = of_find_node_by_path(provider_node);
	struct platform_device *existing;
	u32 phandle = 0;
	int ret;

	wonder_np = of_find_node_by_path(wonder_node);
	if (!provider_np || !wonder_np) {
		pr_err("wonder_shim: missing DT node %s or %s\n", provider_node, wonder_node);
		return -ENODEV;
	}
	if (provider_np == wonder_np) {
		pr_err("wonder_shim: provider and wonder nodes must differ\n");
		return -EINVAL;
	}
	if (of_property_read_u32(provider_np, "phandle", &phandle) || !phandle) {
		pr_err("wonder_shim: %pOF has no phandle\n", provider_np);
		return -EINVAL;
	}
	/* wonder.ko looks the provider up with of_find_device_by_node(), which returns the first match. */
	existing = of_find_device_by_node(provider_np);
	if (existing) {
		put_device(&existing->dev);
		pr_err("wonder_shim: %pOF already has a device\n", provider_np);
		return -EBUSY;
	}
	if (of_find_property(wonder_np, PROVIDER_PROP, NULL)) {
		pr_err("wonder_shim: %pOF already has %s\n", wonder_np, PROVIDER_PROP);
		return -EEXIST;
	}

	provider_prop = new_phandle_property(phandle);
	if (!provider_prop)
		return -ENOMEM;
	ret = of_add_property(wonder_np, provider_prop);
	if (ret) {
		pr_err("wonder_shim: adding %s to %pOF failed: %d\n", PROVIDER_PROP, wonder_np, ret);
		provider_prop = NULL;	/* the kernel may still reference it; leak rather than free */
		return ret;
	}

	mutex_lock(&shim_lock);
	provider_pdev = add_device("wonder-provider-shim", provider_np);
	mutex_unlock(&shim_lock);
	if (IS_ERR(provider_pdev)) {
		ret = PTR_ERR(provider_pdev);
		goto fail;
	}
	wonder_pdev = add_device("wonder", wonder_np);
	if (IS_ERR(wonder_pdev)) {
		ret = PTR_ERR(wonder_pdev);
		goto fail;
	}
	pr_info("wonder_shim: provider %pOF (phandle 0x%x), wonder device on %pOF\n",
		provider_np, phandle, wonder_np);
	return 0;

fail:
	pr_err("wonder_shim: creating devices failed: %d\n", ret);
	remove_devices();
	return ret;
}

static void __exit wonder_shim_exit(void)
{
	remove_devices();
}

module_init(wonder_shim_init);
module_exit(wonder_shim_exit);

MODULE_DESCRIPTION("Wonder glue for vivo PD2547 CN without wonder DT nodes");
MODULE_LICENSE("GPL");
