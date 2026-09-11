ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Threads

TWEAK_NAME = ThreadsNoSpoiler
ThreadsNoSpoiler_FILES = Tweak.xm TSBFooterLayout.mm
ThreadsNoSpoiler_CFLAGS = -fobjc-arc
ThreadsNoSpoiler_FRAMEWORKS = UIKit

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
