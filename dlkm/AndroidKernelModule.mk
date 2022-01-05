ifneq ($(call is-board-platform-in-list,taro parrot neo), true)

# Get the number of CPU cores. This is the number of parallel jobs to be passed to make command.
NCORES := $(shell grep -c ^processor /proc/cpuinfo)
ifeq ($(NCORES),)
  NCORES := 8
endif

DISABLE_THIS_DLKM := $(strip $(TARGET_KERNEL_DLKM_DISABLE))

ifeq ($(DISABLE_THIS_DLKM),true)
ifneq (,$(filter $(LOCAL_MODULE),$(TARGET_KERNEL_DLKM_OVERRIDE)))
    DISABLE_THIS_DLKM = false
else
endif
endif

ifeq ($(DISABLE_THIS_DLKM),true)
$(warning DLKM '$(LOCAL_MODULE)' disabled for target)
else

# Assign external kernel modules to the DLKM class
LOCAL_MODULE_CLASS := DLKM

# Set the default install path to system/lib/modules
LOCAL_MODULE_PATH := $(strip $(LOCAL_MODULE_PATH))
ifeq ($(LOCAL_MODULE_PATH),)
  LOCAL_MODULE_PATH := $(TARGET_OUT)/lib/modules
endif
GKI_LOCAL_MODULE := $(LOCAL_MODULE_PATH)/gki/$(LOCAL_MODULE)

# Set the default Kbuild file path to LOCAL_PATH
KBUILD_FILE := $(strip $(KBUILD_FILE))
ifeq ($(KBUILD_FILE),)
  KBUILD_FILE := $(LOCAL_PATH)/Kbuild
endif

# Get rid of any whitespace
LOCAL_MODULE_KBUILD_NAME := $(strip $(LOCAL_MODULE_KBUILD_NAME))

include $(BUILD_SYSTEM)/base_rules.mk

# Intermediate directory where the kernel modules are created
# by the kernel build system. Ideally this would be the same
# directory as LOCAL_BUILT_MODULE, but because we're using
# relative paths for both O= and M=, we don't have much choice
KBUILD_OUT_DIR := $(TARGET_OUT_INTERMEDIATES)/$(LOCAL_PATH)
KBUILD_OUT_DIR_GKI := $(TARGET_OUT_INTERMEDIATES)/$(LOCAL_PATH)/gki

# The kernel build system doesn't support parallel kernel module builds
# that share the same output directory. Thus, in order to build multiple
# kernel modules that reside in a single directory (and therefore have
# the same output directory), there must be just one invocation of the
# kernel build system that builds all the modules of a given directory.
#
# Therefore, all kernel modules must depend on the same, unique target
# that invokes the kernel build system and builds all of the modules
# for the directory. The $(KBUILD_TARGET) target serves this purpose.
KBUILD_TARGET := $(KBUILD_OUT_DIR)/buildko.timestamp
KBUILD_TARGET_GKI := $(KBUILD_OUT_DIR_GKI)/buildko.timestamp

# Path to the intermediate location where the kernel build
# system creates the kernel module.
KBUILD_MODULE := $(KBUILD_OUT_DIR)/$(LOCAL_MODULE)
KBUILD_MODULE_GKI := $(KBUILD_OUT_DIR_GKI)/$(LOCAL_MODULE)

# Maintain separate kbuild options for gki compilation.
# Default back to KBUILD_OPTIONS
ifeq "$(KBUILD_OPTIONS_GKI)" ""
KBUILD_OPTIONS_GKI := $(KBUILD_OPTIONS)
endif

# Since we only invoke the kernel build system once per directory,
# each kernel module must depend on the same target.
$(KBUILD_MODULE): kbuild_out := $(KBUILD_OUT_DIR)/$(LOCAL_MODULE_KBUILD_NAME)
$(KBUILD_MODULE): $(KBUILD_TARGET)
$(KBUILD_MODULE): $(LOCAL_ADDITIONAL_DEPENDENCIES)
ifneq "$(LOCAL_MODULE_KBUILD_NAME)" ""
	mv -f $(kbuild_out) $@
endif

# To ensure KERNEL_OUT and TARGET_PREBUILT_INT_KERNEL are defined,
# kernel_definitions.mk must be included. While m and regular
# make builds will include kernel_definitions.mk, mm and mmm builds
# do not. Therefore, we need to explicitly include kernel_definitions.mk.
# It is safe to include it more than once because the entire file is
# guarded by "ifeq ($(TARGET_PREBUILT_KERNEL),) ... endif".
# If the kernel_definitions.mk is not found, fallback to the AndroidKernel.mk
ifneq ($(wildcard device/qcom/kernelscripts/kernel_definitions.mk),)
TARGET_KERNEL_PATH := device/qcom/kernelscripts/kernel_definitions.mk
else
TARGET_KERNEL_PATH := $(TARGET_KERNEL_SOURCE)/AndroidKernel.mk
endif
include $(TARGET_KERNEL_PATH)

# Simply copy the kernel module from where the kernel build system
# created it to the location where the Android build system expects it.
# If LOCAL_MODULE_DEBUG_ENABLE is set, strip debug symbols. So that,
# the final images generated by ABS will have the stripped version of
# the modules
ifeq ($(TARGET_KERNEL_VERSION),3.18)
  MODULE_SIGN_FILE := perl ./$(TARGET_KERNEL_SOURCE)/scripts/sign-file
  MODSECKEY := $(KERNEL_OUT)/signing_key.priv
  MODPUBKEY := $(KERNEL_OUT)/signing_key.x509
else
  MODULE_SIGN_FILE := $(KERNEL_OUT)/scripts/sign-file
  MODSECKEY := $(KERNEL_OUT)/certs/signing_key.pem
  MODPUBKEY := $(KERNEL_OUT)/certs/signing_key.x509
endif

# Define a function for signing the module
define sign_module
	mkdir -p $(dir $2)
	cp $1 $1.unstripped
	$(TARGET_STRIP) --strip-debug $1
	cp $1 $1.stripped
	@sh -c "\
	   KMOD_SIG_ALL=`cat $3/.config | grep CONFIG_MODULE_SIG_ALL | cut -d'=' -f2`; \
	   KMOD_SIG_HASH=`cat $3/.config | grep CONFIG_MODULE_SIG_HASH | cut -d'=' -f2 | sed 's/\"//g'`; \
	   if [ \"\$$KMOD_SIG_ALL\" = \"y\" ] && [ -n \"\$$KMOD_SIG_HASH\" ]; then \
	      echo \"Signing kernel module: \" `basename $1`; \
	      cp $1 $1.unsigned; \
	      $(MODULE_SIGN_FILE) \$$KMOD_SIG_HASH $(MODSECKEY) $(MODPUBKEY) $1; \
	   fi; \
	"
endef

$(LOCAL_BUILT_MODULE): local_module_gki := $(GKI_LOCAL_MODULE)
$(LOCAL_BUILT_MODULE): $(KBUILD_MODULE) $(GKI_LOCAL_MODULE) | $(ACP)
	$(call sign_module, $<, $@, $(KERNEL_OUT))
	$(transform-prebuilt-to-target)


# Ensure the kernel module created by the kernel build system, as
# well as all the other intermediate files, are removed during a clean.
$(cleantarget): PRIVATE_CLEAN_FILES := $(PRIVATE_CLEAN_FILES) $(KBUILD_OUT_DIR)

# Add a separate target for gki which can be invoked from
# kernel_defintions.mk. This target will be invoked to compile gki modules
# for qgki builds.
$(GKI_LOCAL_MODULE): kbuild_module_gki := $(KBUILD_MODULE_GKI)
$(GKI_LOCAL_MODULE): kbuild_out_gki := $(KBUILD_OUT_DIR_GKI)/$(LOCAL_MODULE_KBUILD_NAME)
$(GKI_LOCAL_MODULE): $(KBUILD_TARGET_GKI)
ifneq ($(GKI_KERNEL_OUT),)
ifneq "$(LOCAL_MODULE_KBUILD_NAME)" ""
	mv -f $(kbuild_out_gki) $(kbuild_module_gki)
endif
	$(call sign_module, $(kbuild_module_gki), $@, $(GKI_KERNEL_OUT))
	cp -f $(kbuild_module_gki) $@
endif

# This should really be cleared in build/core/clear-vars.mk, but for
# the time being, we need to clear it ourselves
LOCAL_MODULE_KBUILD_NAME :=
LOCAL_MODULE_DEBUG_ENABLE :=

# Since this file will be included more than once for directories
# with more than one kernel module, the shared KBUILD_TARGET rule should
# only be defined once to avoid "overriding commands ..." warnings.
ifndef $(KBUILD_TARGET)_RULE
$(KBUILD_TARGET)_RULE := 1

# Kernel modules have to be built after:
#  * the kernel config has been created
#  * host executables, like scripts/basic/fixdep, have been built
#    (otherwise parallel invocations of the kernel build system will
#    fail as they all try to compile these executables at the same time)
#  * a full kernel build (to make module versioning work)
#
# For these reasons, kernel modules are dependent on
# TARGET_PREBUILT_INT_KERNEL which will ensure all of the above.
#
# NOTE: Due to a bug in the kernel build system when using a Kbuild file
#       and relative paths for both O= and M=, the Kbuild file must
#       be copied to the output directory.
#
# NOTE: The following paths are equivalent:
#         $(KBUILD_OUT_DIR)
#         $(KERNEL_OUT)/../$(LOCAL_PATH)


$(KBUILD_TARGET): local_path     := $(LOCAL_PATH)
$(KBUILD_TARGET): kbuild_options := $(KBUILD_OPTIONS)
$(KBUILD_TARGET): kbuild_out_dir := $(KBUILD_OUT_DIR)
$(KBUILD_TARGET): $(TARGET_PREBUILT_INT_KERNEL) $(GKI_TARGET_PREBUILT_KERNEL) $(LOCAL_ADDITIONAL_DEPENDENCIES) $(KBUILD_TARGET_GKI)
	@mkdir -p $(kbuild_out_dir)
	$(hide) cp -f $(local_path)/Kbuild $(kbuild_out_dir)/Kbuild
	$(MAKE) -j$(NCORES) -C $(KERNEL_OUT) M=$(KERNEL_TO_BUILD_ROOT_OFFSET)$(local_path) ARCH=$(KERNEL_ARCH) CROSS_COMPILE=$(KERNEL_CROSS_COMPILE) $(real_cc) $(KERNEL_CFLAGS) modules $(kbuild_options) ANDROID_BUILD_TOP=$$(pwd)
	touch $@

# Define a target to build buildko.timestamp for gki modules as well.
# To maintain GKI1.0 compatibility modules are compiled for gki and
# qgki kernels. This target only runs if qgki kernel is being compiled.

$(KBUILD_TARGET_GKI): local_path     := $(LOCAL_PATH)
$(KBUILD_TARGET_GKI): local_module     := $(LOCAL_MODULE)
$(KBUILD_TARGET_GKI): kbuild_out_dir_gki := $(KBUILD_OUT_DIR)/gki
$(KBUILD_TARGET_GKI): kbuild_options_gki := $(KBUILD_OPTIONS_GKI)
$(KBUILD_TARGET_GKI): kbuild_out_dir := $(KBUILD_OUT_DIR)
$(KBUILD_TARGET_GKI): local_depends := $(LOCAL_ADDITIONAL_DEPENDENCIES)
$(KBUILD_TARGET_GKI): $(TARGET_PREBUILT_INT_KERNEL) $(LOCAL_ADDITIONAL_DEPENDENCIES) $(GKI_TARGET_PREBUILT_KERNEL)
ifneq ($(GKI_KERNEL_OUT),)
	rm -rf $(kbuild_out_dir)
	mkdir -p $(kbuild_out_dir)
	$(hide) cp -f $(local_path)/Kbuild $(kbuild_out_dir)/Kbuild
	$(MAKE) -j$(NCORES) -C $(GKI_KERNEL_OUT) M=$(KERNEL_TO_BUILD_ROOT_OFFSET)$(local_path) ARCH=$(KERNEL_ARCH) CROSS_COMPILE=$(KERNEL_CROSS_COMPILE) $(real_cc) $(KERNEL_CFLAGS) modules $(kbuild_options_gki) ANDROID_BUILD_TOP=$$(pwd)
	@mkdir -p $(TARGET_OUT_INTERMEDIATES)/tmp_$(local_module)
	mv $(kbuild_out_dir)/* $(TARGET_OUT_INTERMEDIATES)/tmp_$(local_module)
	@mkdir -p $(kbuild_out_dir_gki)
	mv $(TARGET_OUT_INTERMEDIATES)/tmp_$(local_module)/* $(kbuild_out_dir_gki)
	rm -rf $(TARGET_OUT_INTERMEDIATES)/tmp_$(local_module)
	touch $@
endif

# Once the KBUILD_OPTIONS variable has been used for the target
# that's specific to the LOCAL_PATH, clear it. If this isn't done,
# then every kernel module would need to explicitly set KBUILD_OPTIONS,
# or the variable would have to be cleared in 'include $(CLEAR_VARS)'
# which would require a change to build/core.
KBUILD_OPTIONS :=
LOCAL_ADDITIONAL_DEPENDENCIES :=
endif
KBUILD_OPTIONS_GKI :=
endif
endif
