// An A8_UNORM render target (aoe2 N3, G-TEXT): AoE2DE's menus create A8_UNORM textures bound as render target and
// shader resource. Checks, through D3D11 on the runtime: a draw of (0.25, 0.5, 0.75, 0.6) into an A8 target stores the
// alpha (153); a clear with alpha 0.25 stores 64; and sampling the A8 texture returns (0, 0, 0, a), read back from an
// RGBA8 target. Shaders are compiled at run time with d3dcompiler_47.
// Usage: <exe>   Prints "PASS <name>" when every value matches (within 1).
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(__x86_64__) && !defined(__arm64ec__)
#define NAME "x64-d3d11a8"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64ec-d3d11a8"
#endif

#define N 16

typedef HRESULT (WINAPI *compile_fn)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *,
                                     const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

static const char src[] =
  "Texture2D tex : register(t0); SamplerState smp : register(s0);\n"
  "struct V { float4 pos : SV_Position; float2 uv : TEXCOORD0; };\n"
  "V vs(uint id : SV_VertexID) { V o; float2 p = float2((id & 1) ? 1.0 : -1.0, (id & 2) ? -1.0 : 1.0);\n"
  "  o.pos = float4(p, 0, 1); o.uv = float2((p.x + 1) * 0.5, (1 - p.y) * 0.5); return o; }\n"
  "float4 ps_color(V i) : SV_Target { return float4(0.25, 0.5, 0.75, 0.6); }\n"
  "float4 ps_sample(V i) : SV_Target { return tex.SampleLevel(smp, i.uv, 0); }\n";

static int fails;

static ID3DBlob *compile(compile_fn fn, const char *entry, const char *target) {
  ID3DBlob *code = NULL, *errors = NULL;
  if (FAILED(fn(src, sizeof(src) - 1, "a8", NULL, NULL, entry, target, 0, 0, &code, &errors))) {
    printf("compile %s: %s\n", entry, errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "failed");
    exit(1);
  }
  return code;
}

static ID3D11Texture2D *texture(ID3D11Device *dev, DXGI_FORMAT fmt, D3D11_USAGE usage, UINT bind, UINT cpu) {
  D3D11_TEXTURE2D_DESC td = {0};
  ID3D11Texture2D *t = NULL;
  td.Width = td.Height = N; td.MipLevels = td.ArraySize = 1; td.Format = fmt; td.SampleDesc.Count = 1;
  td.Usage = usage; td.BindFlags = bind; td.CPUAccessFlags = cpu;
  if (FAILED(ID3D11Device_CreateTexture2D(dev, &td, NULL, &t))) { printf("CreateTexture2D(%u) failed\n", fmt); exit(1); }
  return t;
}

// Reads texel (N/2, N/2) of a texture through a staging copy; bytes = 1 (A8) or 4 (RGBA8).
static UINT32 read_texel(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *src_tex, DXGI_FORMAT fmt, int bytes) {
  ID3D11Texture2D *st = texture(dev, fmt, D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_READ);
  D3D11_MAPPED_SUBRESOURCE m;
  UINT32 v = 0;
  ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)st, (ID3D11Resource *)src_tex);
  if (FAILED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)st, 0, D3D11_MAP_READ, 0, &m))) { printf("Map failed\n"); exit(1); }
  memcpy(&v, (const BYTE *)m.pData + (N / 2) * m.RowPitch + (N / 2) * bytes, bytes);
  ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)st, 0);
  ID3D11Texture2D_Release(st);
  return v;
}

static void expect(const char *what, int got, int want) {
  int ok = abs(got - want) <= 1;
  printf("%s: %d, expected %d%s\n", what, got, want, ok ? "" : "  <-- wrong");
  if (!ok) fails++;
}

int main(void) {
  HMODULE dc = LoadLibraryA("d3dcompiler_47.dll");
  compile_fn fn = dc ? (compile_fn)(void *)GetProcAddress(dc, "D3DCompile") : NULL;
  D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0, got;
  ID3D11Device *dev; ID3D11DeviceContext *ctx;
  ID3D11Texture2D *a8, *rgba; ID3D11RenderTargetView *a8_rtv, *rgba_rtv; ID3D11ShaderResourceView *a8_srv;
  ID3D11VertexShader *vs; ID3D11PixelShader *ps_color, *ps_sample; ID3D11SamplerState *smp;
  ID3DBlob *b;
  D3D11_SAMPLER_DESC sd = {0};
  D3D11_VIEWPORT vp = { 0, 0, N, N, 0, 1 };
  const float clear_color[4] = { 1.0f, 0.5f, 0.0f, 0.25f };
  UINT32 v;
  setvbuf(stdout, NULL, _IONBF, 0);
  if (!fn) { printf("no D3DCompile\n"); return 1; }
  if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &fl, 1, D3D11_SDK_VERSION, &dev, &got, &ctx))) {
    printf("D3D11CreateDevice failed\n");
    return 1;
  }
  b = compile(fn, "vs", "vs_5_0");
  ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &vs);
  b = compile(fn, "ps_color", "ps_5_0");
  ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &ps_color);
  b = compile(fn, "ps_sample", "ps_5_0");
  ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &ps_sample);
  a8 = texture(dev, DXGI_FORMAT_A8_UNORM, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE, 0);
  rgba = texture(dev, DXGI_FORMAT_R8G8B8A8_UNORM, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0);
  ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)a8, NULL, &a8_rtv);
  ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)a8, NULL, &a8_srv);
  ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)rgba, NULL, &rgba_rtv);
  sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT; sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.MaxLOD = D3D11_FLOAT32_MAX;
  ID3D11Device_CreateSamplerState(dev, &sd, &smp);
  ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
  ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);

  // 1. Clear: the A8 texel holds the clear color's alpha.
  ID3D11DeviceContext_ClearRenderTargetView(ctx, a8_rtv, clear_color);
  expect("clear (alpha 0.25) into A8", (int)read_texel(dev, ctx, a8, DXGI_FORMAT_A8_UNORM, 1), 64);

  // 2. Draw: the A8 texel holds the shader's alpha.
  ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &a8_rtv, NULL);
  ID3D11DeviceContext_PSSetShader(ctx, ps_color, NULL, 0);
  ID3D11DeviceContext_Draw(ctx, 4, 0);
  ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
  expect("draw (alpha 0.6) into A8", (int)read_texel(dev, ctx, a8, DXGI_FORMAT_A8_UNORM, 1), 153);

  // 3. Sample: the shader sees (0, 0, 0, a).
  ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rgba_rtv, NULL);
  ID3D11DeviceContext_PSSetShader(ctx, ps_sample, NULL, 0);
  ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &a8_srv);
  ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &smp);
  ID3D11DeviceContext_Draw(ctx, 4, 0);
  ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
  v = read_texel(dev, ctx, rgba, DXGI_FORMAT_R8G8B8A8_UNORM, 4);
  expect("sampled A8: r", v & 0xff, 0);
  expect("sampled A8: g", (v >> 8) & 0xff, 0);
  expect("sampled A8: b", (v >> 16) & 0xff, 0);
  expect("sampled A8: a", v >> 24, 153);

  if (fails) { printf("FAIL " NAME " (%d)\n", fails); return 1; }
  printf("PASS " NAME "\n");
  return 0;
}
