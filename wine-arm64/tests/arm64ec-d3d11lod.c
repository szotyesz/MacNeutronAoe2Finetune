// Implicit-LOD sampling as AoE2DE's SDF text shader does it (aoe2 N3, G-TEXT): a 64x64 texture with 7 mip levels,
// each a different solid color, drawn at one texel per pixel into a 64x64 target must show mip 0, with the sampler's
// MinLOD at 0 and at -FLT_MAX (the D3D11 default, which the game's samplers use). And ddx_coarse of a coordinate that
// spans the 64-pixel target is 1/64 (the shader scales the SDF edge by it). Shaders are compiled at run time.
// Usage: <exe>   Prints "PASS <name>" when every value matches.
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>
#include <float.h>

#if defined(__x86_64__) && !defined(__arm64ec__)
#define NAME "x64-d3d11lod"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64ec-d3d11lod"
#endif

#define S 64
#define MIPS 7

typedef HRESULT (WINAPI *compile_fn)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *,
                                     const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

static const char src[] =
  "Texture2D tex : register(t0); SamplerState smp : register(s0);\n"
  "struct V { float4 pos : SV_Position; float2 uv : TEXCOORD0; };\n"
  "V vs(uint id : SV_VertexID) { V o; float2 p = float2((id & 1) ? 1.0 : -1.0, (id & 2) ? -1.0 : 1.0);\n"
  "  o.pos = float4(p, 0, 1); o.uv = float2((p.x + 1) * 0.5, (1 - p.y) * 0.5); return o; }\n"
  "float4 ps_sample(V i) : SV_Target { return tex.Sample(smp, i.uv); }\n"
  "float4 ps_ddx(V i) : SV_Target { float d = ddx_coarse(i.uv.x) * 64.0; return float4(saturate(d * 0.5), 0, 0, 1); }\n";

static const UINT32 mip_color[MIPS] = { 0xff0000ffu, 0xff00ff00u, 0xffff0000u, 0xff00ffffu, 0xffff00ffu, 0xffffff00u, 0xff808080u };
static int fails;

static ID3DBlob *compile(compile_fn fn, const char *entry, const char *target) {
  ID3DBlob *code = NULL, *errors = NULL;
  if (FAILED(fn(src, sizeof(src) - 1, "lod", NULL, NULL, entry, target, 0, 0, &code, &errors))) {
    printf("compile %s: %s\n", entry, errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "failed");
    exit(1);
  }
  return code;
}

static UINT32 center(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *rt) {
  D3D11_TEXTURE2D_DESC td; ID3D11Texture2D *st; D3D11_MAPPED_SUBRESOURCE m; UINT32 v;
  ID3D11Texture2D_GetDesc(rt, &td);
  td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Device_CreateTexture2D(dev, &td, NULL, &st);
  ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)st, (ID3D11Resource *)rt);
  ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)st, 0, D3D11_MAP_READ, 0, &m);
  v = ((const UINT32 *)((const BYTE *)m.pData + (S / 2) * m.RowPitch))[S / 2];
  ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)st, 0);
  ID3D11Texture2D_Release(st);
  return v;
}

int main(void) {
  HMODULE dc = LoadLibraryA("d3dcompiler_47.dll");
  compile_fn fn = dc ? (compile_fn)(void *)GetProcAddress(dc, "D3DCompile") : NULL;
  D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0, got;
  ID3D11Device *dev; ID3D11DeviceContext *ctx; ID3D11Texture2D *tex, *rt; ID3D11ShaderResourceView *srv;
  ID3D11RenderTargetView *rtv; ID3D11VertexShader *vs; ID3D11PixelShader *ps_sample, *ps_ddx; ID3DBlob *b;
  D3D11_TEXTURE2D_DESC td = {0}; D3D11_SUBRESOURCE_DATA init[MIPS]; static UINT32 data[MIPS][S * S];
  D3D11_VIEWPORT vp = { 0, 0, S, S, 0, 1 };
  const float minlods[2] = { 0.0f, -FLT_MAX };
  int i, j;
  setvbuf(stdout, NULL, _IONBF, 0);
  if (!fn) { printf("no D3DCompile\n"); return 1; }
  if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &fl, 1, D3D11_SDK_VERSION, &dev, &got, &ctx))) {
    printf("D3D11CreateDevice failed\n");
    return 1;
  }
  b = compile(fn, "vs", "vs_5_0");
  ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &vs);
  b = compile(fn, "ps_sample", "ps_5_0");
  ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &ps_sample);
  b = compile(fn, "ps_ddx", "ps_5_0");
  ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &ps_ddx);
  for (i = 0; i < MIPS; i++) {
    int w = S >> i;
    for (j = 0; j < w * w; j++) data[i][j] = mip_color[i];
    init[i].pSysMem = data[i]; init[i].SysMemPitch = w * 4; init[i].SysMemSlicePitch = 0;
  }
  td.Width = td.Height = S; td.MipLevels = MIPS; td.ArraySize = 1; td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_IMMUTABLE; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  ID3D11Device_CreateTexture2D(dev, &td, init, &tex);
  ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)tex, NULL, &srv);
  td.MipLevels = 1; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_RENDER_TARGET;
  ID3D11Device_CreateTexture2D(dev, &td, NULL, &rt);
  ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)rt, NULL, &rtv);
  ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
  ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
  ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
  ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &srv);

  for (i = 0; i < 2; i++) {
    D3D11_SAMPLER_DESC sd = {0}; ID3D11SamplerState *smp; UINT32 v;
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR; sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MaxAnisotropy = 16; sd.ComparisonFunc = D3D11_COMPARISON_NEVER; sd.MinLOD = minlods[i]; sd.MaxLOD = FLT_MAX;
    ID3D11Device_CreateSamplerState(dev, &sd, &smp);
    ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &smp);
    ID3D11DeviceContext_PSSetShader(ctx, ps_sample, NULL, 0);
    ID3D11DeviceContext_Draw(ctx, 4, 0);
    v = center(dev, ctx, rt);
    printf("MinLOD %g: center %08x, mip 0 is %08x%s\n", minlods[i], v, mip_color[0], v == mip_color[0] ? "" : "  <-- wrong");
    if (v != mip_color[0]) {
      for (j = 1; j < MIPS; j++) if (v == mip_color[j]) printf("  that is mip %d\n", j);
      fails++;
    }
  }
  {
    UINT32 v;
    ID3D11DeviceContext_PSSetShader(ctx, ps_ddx, NULL, 0);
    ID3D11DeviceContext_Draw(ctx, 4, 0);
    v = center(dev, ctx, rt) & 0xff;
    printf("ddx_coarse(u) * 64 * 0.5: %u/255, expected 128%s\n", v, abs((int)v - 128) <= 2 ? "" : "  <-- wrong");
    if (abs((int)v - 128) > 2) fails++;
  }
  if (fails) { printf("FAIL " NAME " (%d)\n", fails); return 1; }
  printf("PASS " NAME "\n");
  return 0;
}
