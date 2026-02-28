//! Application runtime for Windows using the native Win32 API.
//! This creates a window with an OpenGL 4.3 core profile context
//! and runs a Win32 message loop.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const CoreApp = @import("../App.zig");

pub const resourcesDir = internal_os.resourcesDir;

const log = std.log.scoped(.windows_app);

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
    const PAINTSTRUCT = extern struct {
        hdc: HDC,
        fErase: BOOL,
        rcPaint: RECT,
        fRestore: BOOL,
        fIncUpdate: BOOL,
        rgbReserved: [32]u8,
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
    const WM_NCCREATE = 0x0081;

    // Window style constants
    const WS_OVERLAPPEDWINDOW = 0x00CF0000;
    const WS_VISIBLE = 0x10000000;
    const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

    // Window class style constants
    const CS_HREDRAW = 0x0002;
    const CS_VREDRAW = 0x0001;
    const CS_OWNDC = 0x0020;
    const COLOR_WINDOW = 5;
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

    // OpenGL constants
    const GL_COLOR_BUFFER_BIT = 0x00004000;

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
    extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
    extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
    extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
    extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) ?HCURSOR;
    extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
    extern "user32" fn SetWindowLongPtrW(hwnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
    extern "user32" fn GetWindowLongPtrW(hwnd: HWND, nIndex: i32) callconv(.winapi) isize;
    extern "user32" fn ValidateRect(hwnd: HWND, lpRect: ?*const RECT) callconv(.winapi) BOOL;
    extern "user32" fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: ?HINSTANCE) callconv(.winapi) BOOL;

    // kernel32
    extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

    // gdi32
    extern "gdi32" fn GetStockObject(i: i32) callconv(.winapi) ?HBRUSH;
    extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
    extern "gdi32" fn SetPixelFormat(hdc: HDC, format: i32, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
    extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

    // opengl32
    extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
    extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.winapi) BOOL;
    extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
    extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "opengl32" fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.winapi) void;
    extern "opengl32" fn glClear(mask: u32) callconv(.winapi) void;
    extern "opengl32" fn glViewport(x: i32, y: i32, width: i32, height: i32) callconv(.winapi) void;
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

pub const App = struct {
    core_app: *CoreApp,
    hwnd: ?win32.HWND = null,
    hdc: ?win32.HDC = null,
    hglrc: ?win32.HGLRC = null,

    pub const Options = struct {};

    pub fn init(self: *App, core_app: *CoreApp, _: Options) !void {
        self.* = .{ .core_app = core_app };

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
            // Store self pointer in window user data so wndProc can access it
            _ = win32.SetWindowLongPtrW(h, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
            log.info("Window created successfully", .{});
        } else {
            log.err("Failed to create window, error={}", .{win32.GetLastError()});
            return error.WindowCreationFailed;
        }

        try self.initOpenGL();
    }

    /// Initialize OpenGL context on the window.
    /// Uses a dummy window to load WGL extensions, then creates an
    /// OpenGL 4.3 core profile context on the real window.
    fn initOpenGL(self: *App) !void {
        const hwnd = self.hwnd orelse return error.NoWindow;
        const hInstance = win32.GetModuleHandleW(null);

        // --- Phase 1: Create dummy window to load WGL extensions ---
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

        if (win32.RegisterClassExW(&dummy_wc) == 0) {
            log.err("Failed to register dummy GL class", .{});
            return error.DummyClassRegistrationFailed;
        }

        const dummy_hwnd = win32.CreateWindowExW(
            0,
            dummy_class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            0, // invisible
            0, 0, 1, 1,
            null, null, hInstance, null,
        ) orelse {
            log.err("Failed to create dummy GL window", .{});
            return error.DummyWindowCreationFailed;
        };

        const dummy_hdc = win32.GetDC(dummy_hwnd) orelse {
            _ = win32.DestroyWindow(dummy_hwnd);
            return error.GetDCFailed;
        };

        // Set pixel format on dummy
        const dummy_pf = win32.ChoosePixelFormat(dummy_hdc, &pfd);
        if (dummy_pf == 0) {
            _ = win32.DestroyWindow(dummy_hwnd);
            return error.ChoosePixelFormatFailed;
        }
        if (win32.SetPixelFormat(dummy_hdc, dummy_pf, &pfd) == 0) {
            _ = win32.DestroyWindow(dummy_hwnd);
            return error.SetPixelFormatFailed;
        }

        // Create legacy context on dummy
        const dummy_ctx = win32.wglCreateContext(dummy_hdc) orelse {
            _ = win32.DestroyWindow(dummy_hwnd);
            return error.LegacyContextCreationFailed;
        };
        if (win32.wglMakeCurrent(dummy_hdc, dummy_ctx) == 0) {
            _ = win32.wglDeleteContext(dummy_ctx);
            _ = win32.DestroyWindow(dummy_hwnd);
            return error.MakeCurrentFailed;
        }

        // Load wglCreateContextAttribsARB
        const wglCreateContextAttribsARB: ?win32.WglCreateContextAttribsARB = @ptrCast(
            win32.wglGetProcAddress("wglCreateContextAttribsARB"),
        );

        // Clean up dummy
        _ = win32.wglMakeCurrent(null, null);
        _ = win32.wglDeleteContext(dummy_ctx);
        _ = win32.DestroyWindow(dummy_hwnd);
        _ = win32.UnregisterClassW(dummy_class_name, hInstance);

        // --- Phase 2: Create real OpenGL context ---
        const hdc = win32.GetDC(hwnd) orelse return error.GetDCFailed;
        self.hdc = hdc;

        const pixel_format = win32.ChoosePixelFormat(hdc, &pfd);
        if (pixel_format == 0) {
            log.err("Failed to choose pixel format, error={}", .{win32.GetLastError()});
            return error.ChoosePixelFormatFailed;
        }
        if (win32.SetPixelFormat(hdc, pixel_format, &pfd) == 0) {
            log.err("Failed to set pixel format, error={}", .{win32.GetLastError()});
            return error.SetPixelFormatFailed;
        }
        log.info("Pixel format set: {}", .{pixel_format});

        // Create OpenGL 4.3 core profile context
        if (wglCreateContextAttribsARB) |createCtxARB| {
            const attribs = [_:0]i32{
                win32.WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
                win32.WGL_CONTEXT_MINOR_VERSION_ARB, 3,
                win32.WGL_CONTEXT_PROFILE_MASK_ARB,  win32.WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            };
            const ctx = createCtxARB(hdc, null, &attribs) orelse {
                log.err("wglCreateContextAttribsARB failed, error={}", .{win32.GetLastError()});
                return error.OpenGLContextCreationFailed;
            };
            self.hglrc = ctx;
            log.info("Created OpenGL 4.3 core profile context", .{});
        } else {
            // Fallback to legacy context (compatibility profile)
            log.warn("wglCreateContextAttribsARB not available, using legacy context", .{});
            const ctx = win32.wglCreateContext(hdc) orelse {
                return error.OpenGLContextCreationFailed;
            };
            self.hglrc = ctx;
        }

        if (win32.wglMakeCurrent(hdc, self.hglrc) == 0) {
            log.err("wglMakeCurrent failed, error={}", .{win32.GetLastError()});
            return error.MakeCurrentFailed;
        }

        // Draw initial frame to confirm OpenGL works
        win32.glClearColor(0.18, 0.0, 0.30, 1.0);
        win32.glClear(win32.GL_COLOR_BUFFER_BIT);
        _ = win32.SwapBuffers(hdc);
        log.info("OpenGL context initialized and first frame rendered", .{});
    }

    pub fn terminate(self: *App) void {
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
    }

    pub fn run(self: *App) !void {
        _ = self;
        log.info("Entering Win32 message loop", .{});
        var msg: win32.MSG = undefined;
        while (win32.GetMessageW(&msg, null, 0, 0) != 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
        log.info("Message loop exited", .{});
    }

    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }

    fn wndProc(hwnd: win32.HWND, msg: u32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
        const app: ?*App = blk: {
            const ptr: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA));
            break :blk if (ptr == 0) null else @ptrFromInt(ptr);
        };

        switch (msg) {
            win32.WM_DESTROY => {
                win32.PostQuitMessage(0);
                return 0;
            },
            win32.WM_PAINT => {
                if (app) |a| {
                    if (a.hdc) |hdc| {
                        win32.glClearColor(0.18, 0.0, 0.30, 1.0);
                        win32.glClear(win32.GL_COLOR_BUFFER_BIT);
                        _ = win32.SwapBuffers(hdc);
                    }
                }
                _ = win32.ValidateRect(hwnd, null);
                return 0;
            },
            win32.WM_SIZE => {
                // lParam: LOWORD = width, HIWORD = height
                const lparam: usize = @bitCast(lParam);
                const width: i32 = @intCast(lparam & 0xFFFF);
                const height: i32 = @intCast((lparam >> 16) & 0xFFFF);
                win32.glViewport(0, 0, width, height);
                return 0;
            },
            else => return win32.DefWindowProcW(hwnd, msg, wParam, lParam),
        }
    }
};

pub const Surface = struct {
    pub fn deinit(self: *Surface) void {
        _ = self;
    }
};
