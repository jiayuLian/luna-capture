TARGET = iphone:clang:16.5:15.0
ARCHS = arm64
DEBUG = 0
FINALPACKAGE = 1
PACKAGE_VERSION = 1.0.0

LIBRARY_NAME = luna_capture
luna_capture_FILES = Entry.m Capture.m HAR.m FloatUI.m
luna_capture_FRAMEWORKS = Foundation UIKit
luna_capture_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
luna_capture_LDFLAGS = -undefined dynamic_lookup

include $(THEOS)/makefiles/library.mk
