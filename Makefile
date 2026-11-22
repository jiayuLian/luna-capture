TARGET = iphone:clang:16.5:15.0
ARCHS = arm64
DEBUG = 0
FINALPACKAGE = 1
PACKAGE_VERSION = 1.4.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = luna_capture
luna_capture_FILES = Entry.m Capture.m FloatUI.m HookTTNet.m HookSession.m
luna_capture_FRAMEWORKS = Foundation UIKit
luna_capture_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-cast-function-type
luna_capture_LDFLAGS = -Wl,-not_for_dyld_shared_cache

include $(THEOS)/makefiles/library.mk
