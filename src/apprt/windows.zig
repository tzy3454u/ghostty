//! Application runtime for Windows using the native Win32 API.
//! This creates a window with an OpenGL 4.3 core profile context,
//! connects to Ghostty's renderer and terminal IO, and runs a
//! Win32 message loop.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const input = @import("../input.zig");
const keycodes = @import("../input/keycodes.zig");
const internal_os = @import("../os/main.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");

pub const resourcesDir = internal_os.resourcesDir;

const log = std.log.scoped(.windows_app);

// ---------------------------------------------------------------
// Module-level helper functions called from renderer (OpenGL.zig)
// ---------------------------------------------------------------

/// Swap the back buffer of the current WGL context.
/// Called from OpenGL.drawFrameEnd on the renderer thread.
pub fn swapCurrentBuffers() void {
    const hdc = win32.wglGetCurrentDC();
    if (hdc) |dc| _ = win32.SwapBuffers(dc);
}

/// Update the OpenGL viewport to match the current window client area.
/// Called from OpenGL.drawFrameStart on the renderer thread.
pub fn updateViewport() void {
    const hdc = win32.wglGetCurrentDC() orelse return;
    const hwnd = win32.WindowFromDC(hdc) orelse return;
    var rect: win32.RECT = undefined;
    if (win32.GetClientRect(hwnd, &rect) != 0) {
        const gl = @import("opengl");
        gl.glad.context.Viewport.?(0, 0, rect.right - rect.left, rect.bottom - rect.top);
    }
}

/// Release the current WGL context (make no context current).
/// Called from OpenGL.threadExit on the renderer thread.
pub fn glReleaseCurrentContext() void {
    _ = win32.wglMakeCurrent(null, null);
}

// ---------------------------------------------------------------
// Win32 API bindings
// ---------------------------------------------------------------

const win32 = struct {
    const HINSTANCE = std.os.windows.HINSTANCE;
    const HWND = *opaque {};
    const HDC = *opaque {};
    const HBRUSH = *opaque {};
    const HICON = *opaque {};
    const HCURSOR = *opaque {};
    const HMENU = *opaque {};
    const HGLRC = *opaque {};
    const LPARAM = isize;
    const WPARAM = usize;
    const LRESULT = isize;
    const BOOL = std.os.windows.BOOL;
    const DWORD = std.os.windows.DWORD;
    const LPCWSTR = [*:0]const u16;
    const RECT = extern struct {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    };
    const POINT = extern struct {
        x: i32,
        y: i32,
    };
    const MSG = extern struct {
        hwnd: ?HWND,
        message: u32,
        wParam: WPARAM,
        lParam: LPARAM,
        time: DWORD,
        pt: POINT,
    };
    const WNDCLASSEXW = extern struct {
        cbSize: u32,
        style: u32,
        lpfnWndProc: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT,
        cbClsExtra: i32,
        cbWndExtra: i32,
        hInstance: ?HINSTANCE,
        hIcon: ?HICON,
        hCursor: ?HCURSOR,
        hbrBackground: ?HBRUSH,
        lpszMenuName: ?LPCWSTR,
        lpszClassName: LPCWSTR,
        hIconSm: ?HICON,
    };
    const PIXELFORMATDESCRIPTOR = extern struct {
        nSize: u16,
        nVersion: u16,
        dwFlags: DWORD,
        iPixelType: u8,
        cColorBits: u8,
        cRedBits: u8,
        cRedShift: u8,
        cGreenBits: u8,
        cGreenShift: u8,
        cBlueBits: u8,
        cBlueShift: u8,
        cAlphaBits: u8,
        cAlphaShift: u8,
        cAccumBits: u8,
        cAccumRedBits: u8,
        cAccumGreenBits: u8,
        cAccumBlueBits: u8,
        cAccumAlphaBits: u8,
        cDepthBits: u8,
        cStencilBits: u8,
        cAuxBuffers: u8,
        iLayerType: u8,
        bReserved: u8,
        dwLayerMask: DWORD,
        dwVisibleMask: DWORD,
        dwDamageMask: DWORD,
    };

    // Window message constants
    const WM_DESTROY = 0x0002;
    const WM_SIZE = 0x0005;
    const WM_PAINT = 0x000F;
    const WM_CLOSE = 0x0010;
    const WM_KEYDOWN = 0x0100;
    const WM_KEYUP = 0x0101;
    const WM_CHAR = 0x0102;
    const WM_SYSKEYDOWN = 0x0104;
    const WM_SYSKEYUP = 0x0105;
    const WM_SYSCHAR = 0x0106;
    const WM_USER = 0x0400;

    // PeekMessage constants
    const PM_NOREMOVE = 0x0000;
    const PM_REMOVE = 0x0001;

    // Virtual key constants
    const VK_SHIFT = 0x10;
    const VK_CONTROL = 0x11;
    const VK_MENU = 0x12; // Alt
    const VK_CAPITAL = 0x14; // Caps Lock
    const VK_NUMLOCK = 0x90;
    const VK_LSHIFT = 0xA0;
    const VK_RSHIFT = 0xA1;
    const VK_LCONTROL = 0xA2;
    const VK_RCONTROL = 0xA3;
    const VK_LMENU = 0xA4;
    const VK_RMENU = 0xA5;
    const VK_LWIN = 0x5B;
    const VK_RWIN = 0x5C;

    // Window style constants
    const WS_OVERLAPPEDWINDOW = 0x00CF0000;
    const WS_VISIBLE = 0x10000000;
    const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

    // Window class style constants
    const CS_HREDRAW = 0x0002;
    const CS_VREDRAW = 0x0001;
    const CS_OWNDC = 0x0020;
    const IDC_ARROW = @as(LPCWSTR, @ptrFromInt(32512));

    // SetWindowLongPtr index
    const GWLP_USERDATA = -21;

    // Pixel format constants
    const PFD_DRAW_TO_WINDOW = 0x00000004;
    const PFD_SUPPORT_OPENGL = 0x00000020;
    const PFD_DOUBLEBUFFER = 0x00000001;
    const PFD_TYPE_RGBA = 0;
    const PFD_MAIN_PLANE = 0;

    // WGL ARB constants
    const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
    const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
    const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
    const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;

    // WGL extension function types
    const WglCreateContextAttribsARB = *const fn (
        hdc: HDC,
        hShareContext: ?HGLRC,
        attribList: [*:0]const i32,
    ) callconv(.winapi) ?HGLRC;

    // user32
    extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) u16;
    extern "user32" fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: LPCWSTR,
        lpWindowName: LPCWSTR,
        dwStyle: DWORD,
        x: i32,
        y: i32,
        nWidth: i32,
        nHeight: i32,
        hWndParent: ?HWND,
        hMenu: ?HMENU,
        hInstance: ?HINSTANCE,
        lpParam: ?*anyopaque,
    ) callconv(.winapi) ?HWND;
    extern "user32" fn DefWindowProcW(hwnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
    extern "user32" fn GetMessageW(lpMsg: *MSG, hwnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) BOOL;
    extern "user32" fn PeekMessageW(lpMsg: *MSG, hwnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) callconv(.winapi) BOOL;
    extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
    extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
    extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
    extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
    extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) ?HCURSOR;
    extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
    extern "user32" fn SetWindowLongPtrW(hwnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
    extern "user32" fn GetWindowLongPtrW(hwnd: HWND, nIndex: i32) callconv(.winapi) isize;
    extern "user32" fn ValidateRect(hwnd: HWND, lpRect: ?*const RECT) callconv(.winapi) BOOL;
    extern "user32" fn InvalidateRect(hwnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
    extern "user32" fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: ?HINSTANCE) callconv(.winapi) BOOL;
    extern "user32" fn GetClientRect(hwnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
    extern "user32" fn SetWindowTextW(hwnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;

    extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;
    extern "user32" fn MapVirtualKeyW(uCode: u32, uMapType: u32) callconv(.winapi) u32;

    // kernel32
    extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

    // gdi32
    extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
    extern "gdi32" fn SetPixelFormat(hdc: HDC, format: i32, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
    extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
    extern "gdi32" fn WindowFromDC(hdc: HDC) callconv(.winapi) ?HWND;

    // opengl32
    extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
    extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.winapi) BOOL;
    extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
    extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "opengl32" fn wglGetCurrentDC() callconv(.winapi) ?HDC;
};

/// Standard pixel format descriptor for OpenGL rendering.
const pfd = win32.PIXELFORMATDESCRIPTOR{
    .nSize = @sizeOf(win32.PIXELFORMATDESCRIPTOR),
    .nVersion = 1,
    .dwFlags = win32.PFD_DRAW_TO_WINDOW | win32.PFD_SUPPORT_OPENGL | win32.PFD_DOUBLEBUFFER,
    .iPixelType = win32.PFD_TYPE_RGBA,
    .cColorBits = 32,
    .cRedBits = 0,
    .cRedShift = 0,
    .cGreenBits = 0,
    .cGreenShift = 0,
    .cBlueBits = 0,
    .cBlueShift = 0,
    .cAlphaBits = 8,
    .cAlphaShift = 0,
    .cAccumBits = 0,
    .cAccumRedBits = 0,
    .cAccumGreenBits = 0,
    .cAccumBlueBits = 0,
    .cAccumAlphaBits = 0,
    .cDepthBits = 24,
    .cStencilBits = 8,
    .cAuxBuffers = 0,
    .iLayerType = win32.PFD_MAIN_PLANE,
    .bReserved = 0,
    .dwLayerMask = 0,
    .dwVisibleMask = 0,
    .dwDamageMask = 0,
};

// ---------------------------------------------------------------
// Keyboard helpers
// ---------------------------------------------------------------

/// Extract the scancode from WM_KEYDOWN/WM_KEYUP lParam.
/// Returns a value compatible with keycodes.zig "Win" column.
/// Bits 16-23 = scancode, bit 24 = extended key flag.
fn scancodeFromLparam(lParam: win32.LPARAM) u16 {
    const lparam: u32 = @bitCast(@as(i32, @truncate(lParam)));
    const scancode: u16 = @truncate((lparam >> 16) & 0xFF);
    const extended: u16 = if (lparam & (1 << 24) != 0) 0xe000 else 0;
    return scancode | extended;
}

/// Map a Windows scancode to a Ghostty input.Key.
fn keyFromScancode(scancode: u16) input.Key {
    for (keycodes.entries) |entry| {
        if (entry.native == scancode) return entry.key;
    }
    return .unidentified;
}

/// Read the current keyboard modifier state from Win32.
fn getModifiers() input.Mods {
    const key_pressed = struct {
        fn check(vk: i32) bool {
            return (win32.GetKeyState(vk) & @as(i16, -128)) != 0; // high bit set
        }
    }.check;

    return .{
        .shift = key_pressed(win32.VK_SHIFT),
        .ctrl = key_pressed(win32.VK_CONTROL),
        .alt = key_pressed(win32.VK_MENU),
        .super = key_pressed(win32.VK_LWIN) or key_pressed(win32.VK_RWIN),
        .caps_lock = (win32.GetKeyState(win32.VK_CAPITAL) & 1) != 0,
        .num_lock = (win32.GetKeyState(win32.VK_NUMLOCK) & 1) != 0,
    };
}

/// Encode a UTF-16 code unit (from WM_CHAR wParam) to UTF-8.
fn utf16ToUtf8(codepoint: u21, buf: *[4]u8) []const u8 {
    const len = std.unicode.utf8Encode(codepoint, buf) catch return &.{};
    return buf[0..len];
}

// ---------------------------------------------------------------
// App
// ---------------------------------------------------------------

pub const App = struct {
    core_app: *CoreApp,
    config: configpkg.Config,
    hwnd: ?win32.HWND = null,
    hdc: ?win32.HDC = null,
    hglrc: ?win32.HGLRC = null,
    surface: ?Surface = null,

    pub const Options = struct {};

    pub fn init(self: *App, core_app: *CoreApp, _: Options) !void {
        const alloc = core_app.alloc;

        // Load configuration
        var config = try configpkg.Config.load(alloc);
        errdefer config.deinit();
        try config.finalize();

        self.* = .{
            .core_app = core_app,
            .config = config,
        };

        const hInstance = win32.GetModuleHandleW(null);
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");

        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hInstance,
            .hIcon = null,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };

        if (win32.RegisterClassExW(&wc) == 0) {
            log.err("Failed to register window class", .{});
            return error.WindowClassRegistrationFailed;
        }

        const hwnd = win32.CreateWindowExW(
            0,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
            win32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            800,
            600,
            null,
            null,
            hInstance,
            null,
        );

        if (hwnd) |h| {
            self.hwnd = h;
            _ = win32.SetWindowLongPtrW(h, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
            log.info("Window created successfully", .{});
        } else {
            log.err("Failed to create window, error={}", .{win32.GetLastError()});
            return error.WindowCreationFailed;
        }

        try self.initOpenGL();

        // Create the primary surface (terminal)
        self.surface = .{};
        try self.surface.?.init(self);
    }

    pub fn terminate(self: *App) void {
        if (self.surface) |*s| {
            s.deinit();
            self.surface = null;
        }
        if (self.hglrc) |hglrc| {
            _ = win32.wglMakeCurrent(null, null);
            _ = win32.wglDeleteContext(hglrc);
            self.hglrc = null;
        }
        if (self.hwnd) |hwnd| {
            _ = win32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
        self.hdc = null;
        self.config.deinit();
    }

    pub fn run(self: *App) !void {
        log.info("Entering Win32 message loop", .{});
        var msg: win32.MSG = undefined;
        while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
        log.info("Message loop exited", .{});
        _ = self;
    }

    /// Wake up the event loop from any thread.
    pub fn wakeup(self: *const App) void {
        if (self.hwnd) |hwnd| {
            _ = win32.PostMessageW(hwnd, win32.WM_USER, 0, 0);
        }
    }

    pub fn keyboardLayout(_: *const App) input.KeyboardLayout {
        return .unknown;
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        _ = target;
        switch (action) {
            .quit => {
                if (self.hwnd) |hwnd| _ = win32.DestroyWindow(hwnd);
                return true;
            },
            .set_title => {
                if (self.hwnd) |hwnd| {
                    const title = value.title;
                    // Convert UTF-8 title to UTF-16 for SetWindowTextW
                    var buf: [512]u16 = undefined;
                    const len = std.unicode.utf8ToUtf16Le(&buf, title) catch 0;
                    if (len < buf.len) {
                        buf[len] = 0;
                        _ = win32.SetWindowTextW(hwnd, @ptrCast(&buf));
                    }
                }
                return true;
            },
            else => return false,
        }
    }

    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }

    /// Initialize OpenGL 4.3 core profile context using WGL.
    fn initOpenGL(self: *App) !void {
        const hwnd = self.hwnd orelse return error.NoWindow;
        const hInstance = win32.GetModuleHandleW(null);

        // --- Phase 1: Dummy window to load WGL extensions ---
        const dummy_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDummyGL");
        const dummy_wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = win32.CS_OWNDC,
            .lpfnWndProc = win32.DefWindowProcW,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hInstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = dummy_class_name,
            .hIconSm = null,
        };

        if (win32.RegisterClassExW(&dummy_wc) == 0) return error.DummyClassRegistrationFailed;

        const dummy_hwnd = win32.CreateWindowExW(
            0, dummy_class_name, std.unicode.utf8ToUtf16LeStringLiteral(""), 0,
            0, 0, 1, 1, null, null, hInstance, null,
        ) orelse return error.DummyWindowCreationFailed;

        const dummy_hdc = win32.GetDC(dummy_hwnd) orelse {
            _ = win32.DestroyWindow(dummy_hwnd);
            return error.GetDCFailed;
        };

        const dummy_pf = win32.ChoosePixelFormat(dummy_hdc, &pfd);
        if (dummy_pf == 0) { _ = win32.DestroyWindow(dummy_hwnd); return error.ChoosePixelFormatFailed; }
        if (win32.SetPixelFormat(dummy_hdc, dummy_pf, &pfd) == 0) { _ = win32.DestroyWindow(dummy_hwnd); return error.SetPixelFormatFailed; }

        const dummy_ctx = win32.wglCreateContext(dummy_hdc) orelse {
            _ = win32.DestroyWindow(dummy_hwnd);
            return error.LegacyContextCreationFailed;
        };
        if (win32.wglMakeCurrent(dummy_hdc, dummy_ctx) == 0) {
            _ = win32.wglDeleteContext(dummy_ctx);
            _ = win32.DestroyWindow(dummy_hwnd);
            return error.MakeCurrentFailed;
        }

        const wglCreateContextAttribsARB: ?win32.WglCreateContextAttribsARB = @ptrCast(
            win32.wglGetProcAddress("wglCreateContextAttribsARB"),
        );

        _ = win32.wglMakeCurrent(null, null);
        _ = win32.wglDeleteContext(dummy_ctx);
        _ = win32.DestroyWindow(dummy_hwnd);
        _ = win32.UnregisterClassW(dummy_class_name, hInstance);

        // --- Phase 2: Real OpenGL context ---
        const hdc = win32.GetDC(hwnd) orelse return error.GetDCFailed;
        self.hdc = hdc;

        const pixel_format = win32.ChoosePixelFormat(hdc, &pfd);
        if (pixel_format == 0) return error.ChoosePixelFormatFailed;
        if (win32.SetPixelFormat(hdc, pixel_format, &pfd) == 0) return error.SetPixelFormatFailed;
        log.info("Pixel format set: {}", .{pixel_format});

        if (wglCreateContextAttribsARB) |createCtxARB| {
            const attribs = [_:0]i32{
                win32.WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
                win32.WGL_CONTEXT_MINOR_VERSION_ARB, 3,
                win32.WGL_CONTEXT_PROFILE_MASK_ARB,  win32.WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            };
            self.hglrc = createCtxARB(hdc, null, &attribs) orelse return error.OpenGLContextCreationFailed;
            log.info("Created OpenGL 4.3 core profile context", .{});
        } else {
            log.warn("wglCreateContextAttribsARB not available, using legacy context", .{});
            self.hglrc = win32.wglCreateContext(hdc) orelse return error.OpenGLContextCreationFailed;
        }

        if (win32.wglMakeCurrent(hdc, self.hglrc) == 0) return error.MakeCurrentFailed;
        log.info("OpenGL context initialized", .{});
    }

    fn wndProc(hwnd: win32.HWND, msg: u32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
        const app: ?*App = blk: {
            const ptr: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA));
            break :blk if (ptr == 0) null else @ptrFromInt(ptr);
        };

        switch (msg) {
            win32.WM_CLOSE => {
                // Let the surface close cleanly instead of immediate destroy
                if (app) |a| {
                    if (a.surface) |*s| {
                        if (s.core_surface) |*cs| {
                            cs.close();
                            return 0;
                        }
                    }
                }
                _ = win32.DestroyWindow(hwnd);
                return 0;
            },
            win32.WM_DESTROY => {
                win32.PostQuitMessage(0);
                return 0;
            },
            win32.WM_PAINT => {
                _ = win32.ValidateRect(hwnd, null);
                return 0;
            },
            win32.WM_SIZE => {
                if (app) |a| {
                    if (a.surface) |*s| {
                        const lparam: usize = @bitCast(lParam);
                        const width: u32 = @truncate(lparam & 0xFFFF);
                        const height: u32 = @truncate((lparam >> 16) & 0xFFFF);
                        s.size = .{ .width = width, .height = height };
                        if (s.core_surface) |*cs| {
                            cs.sizeCallback(.{ .width = width, .height = height }) catch |err| {
                                log.warn("sizeCallback error: {}", .{err});
                            };
                        }
                    }
                }
                return 0;
            },
            win32.WM_KEYDOWN,
            win32.WM_SYSKEYDOWN,
            => {
                if (app) |a| {
                    if (a.surface) |*s| {
                        const repeat = (lParam & (1 << 30)) != 0;
                        const action: input.Action = if (repeat) .repeat else .press;
                        const scancode = scancodeFromLparam(lParam);
                        const key = keyFromScancode(scancode);
                        const mods = getModifiers();

                        // Save for WM_CHAR pairing
                        s.pending_key = .{ .key = key, .mods = mods, .action = action };

                        // Check if TranslateMessage already posted a WM_CHAR.
                        // If so, let WM_CHAR handle the event with utf8 text.
                        var peek: win32.MSG = undefined;
                        if (win32.PeekMessageW(&peek, hwnd, win32.WM_CHAR, win32.WM_CHAR, win32.PM_NOREMOVE) != 0) {
                            return 0;
                        }
                        // Also check for WM_SYSCHAR (Alt+key)
                        if (win32.PeekMessageW(&peek, hwnd, win32.WM_SYSCHAR, win32.WM_SYSCHAR, win32.PM_NOREMOVE) != 0) {
                            return 0;
                        }

                        // No WM_CHAR coming: send key event without text
                        if (s.core_surface) |*cs| {
                            _ = cs.keyCallback(.{
                                .action = action,
                                .key = key,
                                .mods = mods,
                            }) catch |err| {
                                log.warn("keyCallback error: {}", .{err});
                            };
                        }
                        s.pending_key = null;
                    }
                }
                return 0;
            },
            win32.WM_CHAR,
            win32.WM_SYSCHAR,
            => {
                if (app) |a| {
                    if (a.surface) |*s| {
                        if (s.core_surface) |*cs| {
                            const codepoint: u21 = std.math.cast(u21, wParam) orelse 0;
                            // Skip control characters except for direct terminal input
                            if (codepoint >= 32 or codepoint == '\t' or codepoint == '\r' or codepoint == '\n' or codepoint == 0x1b or codepoint == 0x08) {
                                var utf8_buf: [4]u8 = undefined;
                                const utf8 = utf16ToUtf8(codepoint, &utf8_buf);
                                const pending: Surface.PendingKey = s.pending_key orelse .{};
                                s.pending_key = null;

                                _ = cs.keyCallback(.{
                                    .action = pending.action,
                                    .key = pending.key,
                                    .mods = pending.mods,
                                    .utf8 = utf8,
                                }) catch |err| {
                                    log.warn("keyCallback error: {}", .{err});
                                };
                            }
                        }
                    }
                }
                return 0;
            },
            win32.WM_KEYUP,
            win32.WM_SYSKEYUP,
            => {
                if (app) |a| {
                    if (a.surface) |*s| {
                        if (s.core_surface) |*cs| {
                            const scancode = scancodeFromLparam(lParam);
                            const key = keyFromScancode(scancode);
                            const mods = getModifiers();

                            _ = cs.keyCallback(.{
                                .action = .release,
                                .key = key,
                                .mods = mods,
                            }) catch |err| {
                                log.warn("keyCallback error: {}", .{err});
                            };
                        }
                    }
                }
                return 0;
            },
            win32.WM_USER => {
                if (app) |a| {
                    a.core_app.tick(a) catch |err| {
                        log.warn("tick error: {}", .{err});
                    };
                }
                return 0;
            },
            else => return win32.DefWindowProcW(hwnd, msg, wParam, lParam),
        }
    }
};

// ---------------------------------------------------------------
// Surface
// ---------------------------------------------------------------

pub const Surface = struct {
    app: *App = undefined,
    core_surface: ?CoreSurface = null,
    size: apprt.SurfaceSize = .{ .width = 800, .height = 600 },
    cursor_pos: apprt.CursorPos = .{ .x = 0, .y = 0 },
    title: ?[:0]const u8 = null,

    /// Pending key info from WM_KEYDOWN, consumed by WM_CHAR.
    pending_key: ?PendingKey = null,

    const PendingKey = struct {
        key: input.Key = .unidentified,
        mods: input.Mods = .{},
        action: input.Action = .press,
    };

    pub fn init(self: *Surface, app: *App) !void {
        self.app = app;

        // Get the actual client area size
        if (app.hwnd) |hwnd| {
            var rect: win32.RECT = undefined;
            if (win32.GetClientRect(hwnd, &rect) != 0) {
                self.size = .{
                    .width = @intCast(rect.right - rect.left),
                    .height = @intCast(rect.bottom - rect.top),
                };
            }
        }

        // Register with the core app
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Initialize the core surface (this starts renderer + IO threads)
        self.core_surface = undefined;
        try self.core_surface.?.init(
            app.core_app.alloc,
            &app.config,
            app.core_app,
            app,
            self,
        );
    }

    pub fn deinit(self: *Surface) void {
        if (self.core_surface) |*cs| {
            cs.deinit();
            self.core_surface = null;
        }
        self.app.core_app.deleteSurface(self);
    }

    /// Get the core surface pointer (required by the apprt interface).
    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface.?;
    }

    /// Get the runtime App pointer.
    pub fn rtApp(self: *Surface) *App {
        return self.app;
    }

    /// Content scale (DPI ratio). 1.0 = 96 DPI (standard).
    pub fn getContentScale(_: *Surface) !apprt.ContentScale {
        // TODO: detect actual DPI from GetDpiForWindow
        return .{ .x = 1.0, .y = 1.0 };
    }

    /// Get the surface size in pixels.
    pub fn getSize(self: *Surface) !apprt.SurfaceSize {
        return self.size;
    }

    /// Get the window title.
    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    /// Get the cursor position in surface coordinates.
    pub fn getCursorPos(self: *Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    /// Get default environment variables for terminal IO.
    pub fn defaultTermioEnv(self: *Surface) !std.process.EnvMap {
        return internal_os.getEnvMap(self.app.core_app.alloc);
    }

    /// Close the surface.
    pub fn close(self: *Surface, process_active: bool) void {
        _ = process_active;
        if (self.app.hwnd) |hwnd| {
            _ = win32.DestroyWindow(hwnd);
        }
    }

    pub fn supportsClipboard(_: *Surface, clipboard_type: apprt.Clipboard) bool {
        return clipboard_type == .standard;
    }

    pub fn setClipboard(
        _: *Surface,
        _: apprt.Clipboard,
        _: []const apprt.ClipboardContent,
        _: bool,
    ) !void {
        // TODO: implement clipboard write via Win32 API
    }

    pub fn clipboardRequest(
        _: *Surface,
        _: apprt.Clipboard,
        _: apprt.ClipboardRequest,
    ) !bool {
        // TODO: implement clipboard read via Win32 API
        return false;
    }

    // ---- GL context helpers (called from OpenGL.zig) ----

    /// Make the GL context current on the calling thread.
    pub fn glMakeContextCurrent(self: *Surface) void {
        if (self.app.hdc) |hdc| {
            if (self.app.hglrc) |hglrc| {
                _ = win32.wglMakeCurrent(hdc, hglrc);
            }
        }
    }

    /// Release the GL context from the calling thread.
    pub fn glReleaseContext(_: *Surface) void {
        _ = win32.wglMakeCurrent(null, null);
    }
};
