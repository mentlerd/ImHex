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
#include <charconv>

#include <imgui.h>
#include <imgui_internal.h>

using HexMenuItemActionHandler = std::function<void()>;

@interface HexMenuItem : NSMenuItem {
    HexMenuItemActionHandler _handler;
}
@end

@implementation HexMenuItem

- (id) initWithTitle:(NSString *)title keyEquivalent:(NSString *)keyEquivalent handler:(HexMenuItemActionHandler)handler {
    self = [super initWithTitle:title action:@selector(menuAction:) keyEquivalent:keyEquivalent];
    if (self) {
        self.target = self;

        _handler = std::move(handler);
    }
    return self;
}

- (void) menuAction:(NSMenuItem *)item {
    if (item != self) {
        return;
    }
    if (_handler) {
        _handler();
    }
}

@end

namespace ImSubMenu {

class NativeMenuBuilder {
    static NSString* ToObjC(std::string_view utf8) {
        return [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding];
    }

public:
    void Start() {
        auto mainMenu = NSApplication.sharedApplication.mainMenu;
        if (!mainMenu) {
            return;
        }
        
        // Remove all elements except the native menu
        [mainMenu.itemArray enumerateObjectsUsingBlock:^(NSMenuItem* item, NSUInteger idx, BOOL*) {
            if (idx != 0) [mainMenu removeItem:item];
        }];
        
        _root = std::make_unique<TreeNode>(TreeNode{
            .menu = mainMenu
        });
        _stack.clear();
        _stack.push_back(_root.get());
        
        _isBuilding = true;
    }
    
    bool BeginMenuEx(const char* label, const char* icon, bool enabled) {
        if (_isBuilding) {
            Configure(Descend(label), icon, nullptr, false, true);
            
            if (!enabled) {
                Ascend();
                return false;
            }
            return true;
        }
        
        return ImGui::BeginMenuEx(label, icon, enabled);
    }
    
    bool MenuItemEx(const char* label, const char* icon, const char* shortcut, bool selected, bool enabled) {
        auto menuItemID = ImGui::GetIDWithSeed(label, nullptr, ImGui::GetItemID());
        
        if (_isBuilding) {
            // When the corresponding menu item is clicked, schedule an action to be delivered
            auto handler = [this, menuItemID] {
                printf("Scheduling activation of menu item: %d\n", menuItemID);
                
                _activationTarget.emplace(menuItemID);
            };
            
            Configure(Append(label, std::move(handler)), icon, shortcut, selected, enabled);
            return false;
        }
        
        bool activated = ImGui::MenuItemEx(label, icon, shortcut, selected, enabled);
        
        if (_activationTarget == menuItemID) {
            _activationTarget.reset();
            
            activated = true;
        }
        
        return activated;
    }
    
    void Separator() {
        if (_isBuilding) {
            _stack.back()->Separator();
            return;
        }
        
        ImGui::Separator();
    }
    
    void TextUnformatted(const char* text) {
        if (_isBuilding) {
            Append(text);
            return;
        }
        
        ImGui::TextUnformatted(text);
    }
    
    void EndMenu() {
        if (_isBuilding) {
            Ascend();
            return;
        }
        
        ImGui::EndMenu();
    }
    
    void Stop() {
        _isBuilding = false;
    }
    
private:
    struct TreeNode {
        HexMenuItem* menuItem = nil;
        NSMenu* menu = nil;
        
        std::unordered_map<std::string, TreeNode> children;
        
        void AllocSubmenu() {
            if (menu != nil) {
                return;
            }
            
            menu = [[NSMenu alloc] initWithTitle: menuItem.title];
            [menuItem.menu setSubmenu:menu forItem:menuItem];
        }

        void Separator() {
            AllocSubmenu();
            [menu addItem: NSMenuItem.separatorItem];
        }
        
        HexMenuItem* Append(std::string_view label, HexMenuItemActionHandler handler = {}) {
            NSString* title = ToObjC(label);
            
            if (title == nil) {
                title = @"<nil>";
            }
            
            AllocSubmenu();
            
            HexMenuItem* item = [[HexMenuItem alloc] initWithTitle:title keyEquivalent:@"" handler:std::move(handler)];
            [menu addItem:item];
            return item;
        }
        
        TreeNode* Descend(const std::string& label) {
            auto [it, added] = children.try_emplace(label);
            
            if (added) {
                it->second.menuItem = Append(label);
            }
            
            return &it->second;
        }
    };
    
    HexMenuItem* Descend(const std::string& label) {
        auto* newLevel = _stack.back()->Descend(label);
        _stack.push_back(newLevel);
        return newLevel->menuItem;
    }
    
    HexMenuItem* Append(const std::string& label, HexMenuItemActionHandler handler = {}) {
        return _stack.back()->Append(label, std::move(handler));
    }
    
    void Ascend() {
        _stack.pop_back();
    }
    
    void Configure(HexMenuItem* item, const char* icon, const char* shortcut, bool selected, bool enabled) {
        (void) icon;
        
        if (shortcut && shortcut[0]) {
            std::string_view stream(shortcut);
            
            // Parse ImGui shortcut string to OS representation
            NSEventModifierFlags keyEquivalentModifierFlags = 0;
            NSString* keyEquivalent = nil;
            
            auto consume = [&](std::string_view prefix) {
                if (!stream.starts_with(prefix)) {
                    return false;
                }
                stream = stream.substr(prefix.size());
                return true;
            };

            // Consume various keywords and translate them to their equivalent modifier flags
            while (true) {
                if (consume("CAPS + ")) {
                    keyEquivalentModifierFlags |= NSEventModifierFlagCapsLock;
                } else if (consume("SHIFT + ")) {
                    keyEquivalentModifierFlags |= NSEventModifierFlagShift;
                } else if (consume("CONTROL + ")) {
                    keyEquivalentModifierFlags |= NSEventModifierFlagControl;
                } else if (consume("OPT + ")) {
                    keyEquivalentModifierFlags |= NSEventModifierFlagOption;
                } else if (consume("CMD + ")) {
                    keyEquivalentModifierFlags |= NSEventModifierFlagCommand;
                } else if (consume("NUMPAD + ")) {
                    keyEquivalentModifierFlags |= NSEventModifierFlagNumericPad;
                } else if (consume("HELP + ")) {
                    keyEquivalentModifierFlags |= NSEventModifierFlagHelp;
                } else if (consume("FN + ")) {
                    keyEquivalentModifierFlags |= NSEventModifierFlagFunction;
                } else {
                    break;
                }
            }

            // If a single character remains we assume it is printable
            if (stream.size() == 1) {
                keyEquivalent = ToObjC(stream);
            }
            
            // This could be a function row button
            if (keyEquivalent == nil && stream.starts_with("F")) {
                u8 integer;
                
                if (std::from_chars(stream.begin() + 1, stream.end(), integer).ec == std::errc{}) {
                    unichar keyCode = NSF1FunctionKey + integer - 1;
                    
                    if (NSF1FunctionKey <= keyCode && keyCode <= NSF35FunctionKey) {
                        keyEquivalent = [NSString stringWithFormat:@"%C", keyCode];
                    }
                }
            }
            
            // Assign parsed description to the item, but show the original string as a badge
            // in case failed to make sense of it - this way wacky translations are still shown
            if (keyEquivalent != nil) {
                [item setKeyEquivalentModifierMask:keyEquivalentModifierFlags];
                [item setKeyEquivalent:keyEquivalent];
            } else {
                [item setBadge: [[NSMenuItemBadge alloc] initWithString:ToObjC(shortcut)]];
            }
        }
        if (selected) {
            [item setState:NSControlStateValueOn];
        }

        [item setEnabled:enabled];
    }
    
    // Whether we are currently re-building the native OS menu
    bool _isBuilding = false;
    
    std::unique_ptr<TreeNode> _root;
    std::deque<TreeNode*> _stack;
    
    // ID of ImGui element which the menu activation should reach
    std::optional<ImGuiID> _activationTarget;
};

NativeMenuBuilder builder;

bool BeginMainMenuBar() {
    static u64 frameCounter = 0;
    
    if (ImGui::Begin("Debug")) {
        ImGui::Text("Frame: %llu", ++frameCounter);
        
        if (frameCounter % 600 == 30) {
            ImGui::Text("Capturing!");
            builder.Start();
        }
        
        ImGui::End();
    }
    
    return ImGui::BeginMainMenuBar();
}

void Separator() {
    builder.Separator();
}

bool BeginMenu(const char* label, bool enabled) {
    return builder.BeginMenuEx(label, nullptr, enabled);
}

bool BeginMenuEx(const char* label, const char* icon, bool enabled) {
    return builder.BeginMenuEx(label, icon, enabled);
}

void EndMenu() {
    builder.EndMenu();
}

bool MenuItem(const char* label, const char* shortcut, bool selected, bool enabled) {
    return builder.MenuItemEx(label, nullptr, shortcut, selected, enabled);
}

bool MenuItemEx(const char* label, const char* icon, const char* shortcut, bool selected, bool enabled) {
    return builder.MenuItemEx(label, icon, shortcut, selected, enabled);
}

void TextSpinner(const char* text) {
    builder.TextUnformatted(text); // TODO!
}

void TextUnformatted(const char* title) {
    builder.TextUnformatted(title);
}

bool IsShiftPressed() {
    return ImGui::GetIO().KeyShift;
}

void EndMainMenuBar() {
    builder.Stop();
    
    ImGui::EndMainMenuBar();
}

}
