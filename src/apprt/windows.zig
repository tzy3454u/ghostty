//! Application runtime for Windows using the native Win32 API.
//! This is a minimal implementation that creates a window and runs
//! a Win32 message loop.

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
    const CREATESTRUCTW = extern struct {
        lpCreateParams: ?*anyopaque,
        hInstance: ?HINSTANCE,
        hMenu: ?HMENU,
        hwndParent: ?HWND,
        cy: i32,
        cx: i32,
        y: i32,
        x: i32,
        style: i32,
        lpszName: ?LPCWSTR,
        lpszClass: ?LPCWSTR,
        dwExStyle: DWORD,
    };

    // Constants
    const WM_DESTROY = 0x0002;
    const WM_PAINT = 0x000F;
    const WM_NCCREATE = 0x0081;
    const WS_OVERLAPPEDWINDOW = 0x00CF0000;
    const WS_VISIBLE = 0x10000000;
    const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
    const CS_HREDRAW = 0x0002;
    const CS_VREDRAW = 0x0001;
    const CS_OWNDC = 0x0020;
    const COLOR_WINDOW = 5;
    const IDC_ARROW = @as(LPCWSTR, @ptrFromInt(32512));

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
    extern "user32" fn BeginPaint(hwnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
    extern "user32" fn EndPaint(hwnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
    extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) ?HCURSOR;
    extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
    extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
    extern "gdi32" fn GetStockObject(i: i32) callconv(.winapi) ?HBRUSH;
};

pub const App = struct {
    core_app: *CoreApp,
    hwnd: ?win32.HWND = null,

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
            .hbrBackground = win32.GetStockObject(win32.COLOR_WINDOW + 1),
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
            log.info("Window created successfully", .{});
        } else {
            log.err("Failed to create window", .{});
            return error.WindowCreationFailed;
        }
    }

    pub fn terminate(self: *App) void {
        if (self.hwnd) |hwnd| {
            _ = win32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
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
        switch (msg) {
            win32.WM_DESTROY => {
                win32.PostQuitMessage(0);
                return 0;
            },
            win32.WM_PAINT => {
                var ps: win32.PAINTSTRUCT = undefined;
                _ = win32.BeginPaint(hwnd, &ps);
                _ = win32.EndPaint(hwnd, &ps);
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
