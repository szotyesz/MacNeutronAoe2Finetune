// A game's 1920x1080 fullscreen on a display of another aspect (aoe2 to-do: letterbox): lists whether the display
// offers 1920x1080, switches to it, covers the screen with a borderless window, and presents green frames from a
// 1920x1080 D3D11 swapchain for <seconds> (default 10) while the screen can be captured. Prints the mode switch result,
// the window's client rect and the monitor rect Windows reports.
// Usage: x64-letterbox.exe [seconds] [nomode]   Prints "PASS x64-letterbox" when every step succeeds. With "nomode" it
// keeps the desktop's mode and sizes the window and swapchain to it (the control case).
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  return DefWindowProcW(hwnd, msg, wp, lp);
}

int main(int argc, char **argv) {
  int seconds = argc > 1 ? atoi(argv[1]) : 10, found = 0, nomode = argc > 2 && !strcmp(argv[2], "nomode");
  int width = 1920, height = 1080;
  DEVMODEW mode = { .dmSize = sizeof(mode) };
  setvbuf(stdout, NULL, _IONBF, 0);
  for (DWORD i = 0; EnumDisplaySettingsW(NULL, i, &mode); i++)
    if (mode.dmPelsWidth == 1920 && mode.dmPelsHeight == 1080) found = 1;
  printf("1920x1080 offered: %s\n", found ? "yes" : "no");
  LONG change = DISP_CHANGE_SUCCESSFUL;
  if (nomode) {
    width = GetSystemMetrics(SM_CXSCREEN); height = GetSystemMetrics(SM_CYSCREEN);
  } else {
    if (!found) { printf("FAIL x64-letterbox\n"); return 1; }
    DEVMODEW want = { .dmSize = sizeof(want), .dmPelsWidth = 1920, .dmPelsHeight = 1080,
                      .dmFields = DM_PELSWIDTH | DM_PELSHEIGHT };
    change = ChangeDisplaySettingsExW(NULL, &want, NULL, CDS_FULLSCREEN, NULL);
  }
  printf("ChangeDisplaySettingsEx: %ld\n", change);

  WNDCLASSW wc = { .lpfnWndProc = wndproc, .hInstance = GetModuleHandleW(NULL), .lpszClassName = L"letterbox" };
  RegisterClassW(&wc);
  HWND hwnd = CreateWindowExW(WS_EX_TOPMOST, L"letterbox", L"letterbox", WS_POPUP | WS_VISIBLE, 0, 0, width, height,
                              NULL, NULL, wc.hInstance, NULL);
  RECT client; GetClientRect(hwnd, &client);
  MONITORINFO mi = { .cbSize = sizeof(mi) };
  GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &mi);
  printf("client %ldx%ld, monitor %ldx%ld\n", client.right, client.bottom,
         mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top);

  DXGI_SWAP_CHAIN_DESC desc = { .BufferDesc = { .Width = width, .Height = height, .Format = DXGI_FORMAT_R8G8B8A8_UNORM },
                                .SampleDesc = { .Count = 1 }, .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
                                .BufferCount = 2, .OutputWindow = hwnd, .Windowed = TRUE,
                                .SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD };
  IDXGISwapChain *swap; ID3D11Device *dev; ID3D11DeviceContext *ctx; ID3D11Texture2D *back; ID3D11RenderTargetView *rtv;
  HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &desc,
                                             &swap, &dev, NULL, &ctx);
  if (FAILED(hr)) { printf("D3D11CreateDeviceAndSwapChain: %#lx\nFAIL x64-letterbox\n", hr); return 1; }
  swap->lpVtbl->GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back);
  dev->lpVtbl->CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv);
  const float green[4] = { 0.0f, 0.8f, 0.0f, 1.0f };
  DWORD end = GetTickCount() + seconds * 1000;
  while (GetTickCount() < end) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
    ctx->lpVtbl->OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ctx->lpVtbl->ClearRenderTargetView(ctx, rtv, green);
    swap->lpVtbl->Present(swap, 1, 0);
  }
  if (!nomode) ChangeDisplaySettingsExW(NULL, NULL, NULL, 0, NULL);
  printf(change == DISP_CHANGE_SUCCESSFUL ? "PASS x64-letterbox\n" : "FAIL x64-letterbox\n");
  return change == DISP_CHANGE_SUCCESSFUL ? 0 : 1;
}
