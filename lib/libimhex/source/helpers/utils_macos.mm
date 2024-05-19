#if defined(OS_MACOS)

    #include <hex/helpers/utils_macos.hpp>

    #include <CoreFoundation/CFBundle.h>
    #include <ApplicationServices/ApplicationServices.h>
    #include <Foundation/NSUserDefaults.h>
    #include <AppKit/NSScreen.h>
    #include <CoreFoundation/CoreFoundation.h>
    #include <CoreText/CoreText.h>

    #include <string.h>
    #include <stdlib.h>
    #include <stdint.h>

    #define GLFW_EXPOSE_NATIVE_COCOA
    #include <GLFW/glfw3.h>
    #include <GLFW/glfw3native.h>

    #import <Cocoa/Cocoa.h>
    #import <Foundation/Foundation.h>

    void errorMessageMacos(const char *cMessage) {
        CFStringRef strMessage = CFStringCreateWithCString(NULL, cMessage, kCFStringEncodingUTF8);
        CFUserNotificationDisplayAlert(0, kCFUserNotificationStopAlertLevel, NULL, NULL, NULL, strMessage, NULL, NULL, NULL, NULL, NULL);
    }

    extern "C" {
        void openFile(const char *path);
        void registerFont(const char *fontName, const char *fontPath);
    }

    void openWebpageMacos(const char *url) {
        CFURLRef urlRef = CFURLCreateWithBytes(NULL, (uint8_t*)(url), strlen(url), kCFStringEncodingASCII, NULL);
        LSOpenCFURLRef(urlRef, NULL);
        CFRelease(urlRef);
    }

    bool isMacosSystemDarkModeEnabled(void) {
        NSString * appleInterfaceStyle = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];

        if (appleInterfaceStyle && [appleInterfaceStyle length] > 0) {
            return [[appleInterfaceStyle lowercaseString] containsString:@"dark"];
        } else {
            return false;
        }
    }

    float getBackingScaleFactor(void) {
        return [[NSScreen mainScreen] backingScaleFactor];
    }

    void setupMacosWindowStyle(GLFWwindow *window, bool borderlessWindowMode) {
        NSWindow* cocoaWindow = glfwGetCocoaWindow(window);

        cocoaWindow.titleVisibility = NSWindowTitleHidden;

        if (borderlessWindowMode) {
            cocoaWindow.titlebarAppearsTransparent = YES;
            cocoaWindow.styleMask |= NSWindowStyleMaskFullSizeContentView;

            [cocoaWindow setOpaque:NO];
            [cocoaWindow setHasShadow:YES];
            [cocoaWindow setBackgroundColor:[NSColor colorWithWhite: 0 alpha: 0.001f]];
        }
    }

    bool isMacosFullScreenModeEnabled(GLFWwindow *window) {
        NSWindow* cocoaWindow = glfwGetCocoaWindow(window);
        return (cocoaWindow.styleMask & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen;
    }

    void enumerateFontsMacos(void) {
        CFArrayRef fontDescriptors = CTFontManagerCopyAvailableFontFamilyNames();
        CFIndex count = CFArrayGetCount(fontDescriptors);

        for (CFIndex i = 0; i < count; i++) {
            CFStringRef fontName = (CFStringRef)CFArrayGetValueAtIndex(fontDescriptors, i);

            // Get font path
            CFDictionaryRef attributes = (__bridge CFDictionaryRef)@{ (__bridge NSString *)kCTFontNameAttribute : (__bridge NSString *)fontName };
            CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
            CFURLRef fontURL = (CFURLRef) CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute);
            CFStringRef fontPath = CFURLCopyFileSystemPath(fontURL, kCFURLPOSIXPathStyle);

            registerFont([(__bridge NSString *)fontName UTF8String], [(__bridge NSString *)fontPath UTF8String]);

            CFRelease(descriptor);
            CFRelease(fontURL);
        }

        CFRelease(fontDescriptors);
    }

    void macosHandleTitlebarDoubleClickGesture(GLFWwindow *window) {
        NSWindow* cocoaWindow = glfwGetCocoaWindow(window);

        // Consult user preferences: "System Settings -> Desktop & Dock -> Double-click a window's title bar to"
        NSString* action = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleActionOnDoubleClick"];
        
        if (action == nil || [action isEqualToString:@"None"]) {
            // Nothing to do
        } else if ([action isEqualToString:@"Minimize"]) {
            if ([cocoaWindow isMiniaturizable]) {
                [cocoaWindow miniaturize:nil];
            }
        } else if ([action isEqualToString:@"Maximize"]) {
            // `[NSWindow zoom:_ sender]` takes over pumping the main runloop for the duration of the resize,
            // and would interfere with our renderer's frame logic. Schedule it for the next frame
            
            CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
                if ([cocoaWindow isZoomable]) {
                    [cocoaWindow zoom:nil];
                }
            });
        }
    }

    bool macosIsWindowBeingResizedByUser(GLFWwindow *window) {
        NSWindow* cocoaWindow = glfwGetCocoaWindow(window);
        
        return cocoaWindow.inLiveResize;
    }

    @interface HexDocument : NSDocument

    @end

    @implementation HexDocument

    - (BOOL) readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError {
        NSString* urlString = [url absoluteString];
        const char* utf8String = [urlString UTF8String];

        const char *prefix = "file://";
        if (strncmp(utf8String, prefix, strlen(prefix)) == 0)
            utf8String += strlen(prefix);

        openFile(utf8String);

        return YES;
    }

    @end

#endif

#include <hex/api/content_registry.hpp>
#include <hex/api/localization_manager.hpp>

#include <unordered_map>
#include <deque>

#include <imgui.h>
#include <imgui_internal.h>

namespace ImSubMenu {

struct NativeMenuItem {
    NSMenuItem* nsMenuItem = nil;
    
    std::unordered_map<std::string_view, NativeMenuItem> items;
    
    explicit NativeMenuItem(NSMenu* parent, const hex::UnlocalizedString& name) {
        if (name.get() == hex::ContentRegistry::Interface::impl::SeparatorValue) {
            [parent addItem: NSMenuItem.separatorItem];
            return;
        }
        
        hex::Lang localizedName(name);
        NSString* localizedNameStr = [NSString stringWithUTF8String:localizedName.get().c_str()];
        
        if (localizedNameStr == nil) {
            localizedNameStr = @"???";
        }
        
        nsMenuItem = [parent addItemWithTitle:localizedNameStr action:nil keyEquivalent:@""];
    }
    
    void Create(const hex::ContentRegistry::Interface::impl::MenuItem& item, size_t depth) {
        if (nsMenuItem == nil) {
            return;
        }
        if (nsMenuItem.submenu == nil) {
            nsMenuItem.submenu = [[NSMenu alloc] initWithTitle:nsMenuItem.title];
        }
        
        const auto& name = item.unlocalizedNames[depth];
        
        auto [it, added] = items.try_emplace(name, nsMenuItem.submenu, name);
        
        if (depth == item.unlocalizedNames.size() - 1) {
            it->second.Create(item, depth + 1);
            return;
        }
    }
};

struct NativeMenuBuilder {
    std::unordered_map<std::string_view, NativeMenuItem> mainItems;
    std::deque<NativeMenuItem*> stack;

    bool isBuilding = false;
    
    void Start() {
        auto mainMenu = NSApplication.sharedApplication.mainMenu;
        if (!mainMenu) {
            return;
        }
        
        // Remove all elements except the native menu
        [mainMenu.itemArray enumerateObjectsUsingBlock:^(NSMenuItem* item, NSUInteger idx, BOOL*) {
            if (idx != 0) [mainMenu removeItem:item];
        }];

        // Build our own object structure to make menu building more intuitive
        for (const auto& [_, hexMainMenuItem] : hex::ContentRegistry::Interface::impl::getMainMenuItems()) {
            struct NativeMenuItem mainMenuItem(mainMenu, hexMainMenuItem.unlocalizedName);
            
            for (const auto& [_, hexMenuItem] : hex::ContentRegistry::Interface::impl::getMenuItems()) {
                if (hexMenuItem.unlocalizedNames.front() != hexMainMenuItem.unlocalizedName) {
                    continue;
                }
             
                mainMenuItem.Create(hexMenuItem, 1);
            }
        }
    }
    
    void Stop() {
        isBuilding = false;
    }
};

NativeMenuBuilder builder;

bool BeginMainMenuBar() {
    static u64 frameCounter = 0;
    
    if (++frameCounter % 30 == 0) {
        builder.Start();
        builder.Stop();
    }
    
    return ImGui::BeginMainMenuBar();
}

void Separator() {
    ImGui::Separator();
}

bool BeginMenu(const char* title, bool enabled) {
    return ImGui::BeginMenu(title, enabled);
}

bool BeginMenuEx(const char* label, const char* icon, bool enabled) {
    return ImGui::BeginMenuEx(label, icon, enabled);
}

void EndMenu() {
    ImGui::EndMenu();
}

bool MenuItem(const char* title, const char* shortcut, bool selected, bool enabled) {
    return ImGui::MenuItem(title, shortcut, selected, enabled);
}

bool MenuItemEx(const char* title, const char* icon, const char* shortcut, bool selected, bool enabled) {
    return ImGui::MenuItemEx(title, icon, shortcut, selected, enabled);
}

void TextSpinner(const char* title) {
    ImGui::TextUnformatted("%s <spinner>", title); // TODO!
}

void TextUnformatted(const char* title) {
    ImGui::TextUnformatted(title);
}

bool IsShiftPressed() {
    return ImGui::GetIO().KeyShift;
}

void EndMainMenuBar() {
    ImGui::EndMainMenuBar();
}

}
