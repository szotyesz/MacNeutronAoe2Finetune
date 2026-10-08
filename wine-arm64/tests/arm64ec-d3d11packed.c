// Packed interpolants (aoe2 N3, G-TEXT): AoE2DE's menu text vertex shader writes two float2 outputs into one register,
// TEXCOORD0 in o1.xy and TEXCOORD1 in o1.zw, and its gradient text pixel shader reads that register as one float4,
// TEXCOORD0 in v1.xyzw. D3D11 links stages by register, so the pixel shader's v1.zw is the vertex shader's TEXCOORD1.
// Checks that pair, the reverse (one float4 output read as two float2 inputs), and the matching pair, by drawing
// the interpolants as a color into an RGBA8 target and reading the center pixel back. Shaders are compiled at run time.
// Usage: <exe>   Prints "PASS <name>" when every pixel matches (within 1).
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(__x86_64__) && !defined(__arm64ec__)
#define NAME "x64-d3d11packed"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64ec-d3d11packed"
#endif

#define N 16

typedef HRESULT (WINAPI *compile_fn)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *,
                                     const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

static const char src[] =
  "struct V2 { float4 pos : SV_Position; float2 a : TEXCOORD0; float2 b : TEXCOORD1; };\n"
  "struct V4 { float4 pos : SV_Position; float4 t : TEXCOORD0; };\n"
  "float4 quad(uint id) { return float4((id & 1) ? 1.0 : -1.0, (id & 2) ? -1.0 : 1.0, 0, 1); }\n"
  // two float2 outputs, packed into o1.xy and o1.zw
  "V2 vs_two(uint id : SV_VertexID) { V2 o; o.pos = quad(id); o.a = float2(0.25, 0.5); o.b = float2(0.75, 1.0); return o; }\n"
  // one float4 output in o1
  "V4 vs_one(uint id : SV_VertexID) { V4 o; o.pos = quad(id); o.t = float4(0.25, 0.5, 0.75, 1.0); return o; }\n"
  // one float4 input in v1: as the game's gradient text shader
  "float4 ps_one(V4 i) : SV_Target { return float4(i.t.z, i.t.w, i.t.x, i.t.y); }\n"
  // two float2 inputs, v1.xy and v1.zw
  "float4 ps_two(V2 i) : SV_Target { return float4(i.b.x, i.b.y, i.a.x, i.a.y); }\n";

static int fails;

static ID3DBlob *compile(compile_fn fn, const char *entry, const char *target) {
  ID3DBlob *code = NULL, *errors = NULL;
  if (FAILED(fn(src, sizeof(src) - 1, "packed", NULL, NULL, entry, target, 0, 0, &code, &errors))) {
    printf("compile %s: %s\n", entry, errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "failed");
    exit(1);
  }
  return code;
}

int main(void) {
  HMODULE dc = LoadLibraryA("d3dcompiler_47.dll");
  compile_fn fn = dc ? (compile_fn)(void *)GetProcAddress(dc, "D3DCompile") : NULL;
  D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0, got;
  ID3D11Device *dev; ID3D11DeviceContext *ctx; ID3D11Texture2D *rt, *st; ID3D11RenderTargetView *rtv;
  ID3D11VertexShader *vs[2]; ID3D11PixelShader *ps[2]; ID3DBlob *b;
  D3D11_TEXTURE2D_DESC td = {0};
  D3D11_VIEWPORT vp = { 0, 0, N, N, 0, 1 };
  static const char *const vs_names[2] = { "two float2 outputs", "one float4 output" };
  static const char *const ps_names[2] = { "one float4 input", "two float2 inputs" };
  setvbuf(stdout, NULL, _IONBF, 0);
  if (!fn) { printf("no D3DCompile\n"); return 1; }
  if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &fl, 1, D3D11_SDK_VERSION, &dev, &got, &ctx))) {
    printf("D3D11CreateDevice failed\n");
    return 1;
  }
  b = compile(fn, "vs_two", "vs_4_0");
  ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &vs[0]);
  b = compile(fn, "vs_one", "vs_4_0");
  ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &vs[1]);
  b = compile(fn, "ps_one", "ps_5_0");
  ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &ps[0]);
  b = compile(fn, "ps_two", "ps_5_0");
  ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &ps[1]);
  td.Width = td.Height = N; td.MipLevels = td.ArraySize = 1; td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_RENDER_TARGET;
  ID3D11Device_CreateTexture2D(dev, &td, NULL, &rt);
  ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)rt, NULL, &rtv);
  td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Device_CreateTexture2D(dev, &td, NULL, &st);
  ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
  ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
  for (int v = 0; v < 2; v++)
    for (int p = 0; p < 2; p++) {
      static const float clear[4] = { 0, 0, 0, 0 };
      static const int want[4] = { 191, 255, 64, 128 };  // (0.75, 1.0, 0.25, 0.5)
      D3D11_MAPPED_SUBRESOURCE m;
      UINT32 px; int ok = 1;
      ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
      ID3D11DeviceContext_VSSetShader(ctx, vs[v], NULL, 0);
      ID3D11DeviceContext_PSSetShader(ctx, ps[p], NULL, 0);
      ID3D11DeviceContext_Draw(ctx, 4, 0);
      ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)st, (ID3D11Resource *)rt);
      ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)st, 0, D3D11_MAP_READ, 0, &m);
      px = ((const UINT32 *)((const BYTE *)m.pData + (N / 2) * m.RowPitch))[N / 2];
      ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)st, 0);
      for (int c = 0; c < 4; c++) if (abs((int)(px >> (8 * c) & 0xff) - want[c]) > 1) ok = 0;
      printf("%s -> %s: %3u %3u %3u %3u, expected %d %d %d %d%s\n", vs_names[v], ps_names[p], px & 0xff, px >> 8 & 0xff,
             px >> 16 & 0xff, px >> 24, want[0], want[1], want[2], want[3], ok ? "" : "  <-- wrong");
      if (!ok) fails++;
    }
  if (fails) { printf("FAIL " NAME " (%d)\n", fails); return 1; }
  printf("PASS " NAME "\n");
  return 0;
}
