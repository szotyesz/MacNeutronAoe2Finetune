// Texture uploads as AoE2DE's menus make them (aoe2 N3, G-TEXT; from a D3D11 usage log of the main menu):
//  (a) a DYNAMIC B8G8R8A8 texture of odd width, rewritten with Map(WRITE_DISCARD) before each of 16 draws that
//      sample it: draw k must see the data written for it (each discard gets the texture's contents to itself);
//  (b) one STAGING R8G8B8A8 texture reused for 16 uploads: Map(WRITE), fill, Unmap, CopySubresourceRegion into region
//      k of a DEFAULT texture. A Map(WRITE) must not overwrite data a pending copy has yet to read.
// Every band and region is read back and compared with the pattern written for it. Shaders are compiled at run time.
// Usage: <exe>   Prints "PASS <name>" when everything matches.
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(__x86_64__) && !defined(__arm64ec__)
#define NAME "x64-d3d11upload"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64ec-d3d11upload"
#endif

#define DW 301   /* dynamic texture: odd width */
#define DH 7
#define ROUNDS 16
#define BAND 4
#define SW 61    /* staging region */
#define SH 5

typedef HRESULT (WINAPI *compile_fn)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *,
                                     const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

static const char src[] =
  "Texture2D tex : register(t0); SamplerState smp : register(s0);\n"
  "struct V { float4 pos : SV_Position; float2 uv : TEXCOORD0; };\n"
  "V vs(uint id : SV_VertexID) { V o; float2 p = float2((id & 1) ? 1.0 : -1.0, (id & 2) ? -1.0 : 1.0);\n"
  "  o.pos = float4(p, 0, 1); o.uv = float2((p.x + 1) * 0.5, 3.5 / 7.0); return o; }\n"
  "float4 ps(V i) : SV_Target { return tex.SampleLevel(smp, i.uv, 0); }\n";

static UINT32 pat(int k, int x, int y) {  /* B8G8R8A8 / R8G8B8A8 bytes as a little-endian word */
  return (UINT32)((k * 41 + x) & 0xff) | (UINT32)((k * 13 + y * 29 + 5) & 0xff) << 8 |
         (UINT32)((x * 7 + k * 3) & 0xff) << 16 | 0xff000000u;
}
static UINT32 bgra_to_rgba(UINT32 v) { return (v & 0xff00ff00u) | (v & 0xff) << 16 | (v >> 16 & 0xff); }

static ID3DBlob *compile(compile_fn fn, const char *entry, const char *target) {
  ID3DBlob *code = NULL, *errors = NULL;
  if (FAILED(fn(src, sizeof(src) - 1, "upload", NULL, NULL, entry, target, 0, 0, &code, &errors))) {
    printf("compile %s: %s\n", entry, errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "failed");
    exit(1);
  }
  return code;
}

static ID3D11Texture2D *texture(ID3D11Device *dev, UINT w, UINT h, DXGI_FORMAT fmt, D3D11_USAGE usage, UINT bind, UINT cpu) {
  D3D11_TEXTURE2D_DESC td = {0};
  ID3D11Texture2D *t = NULL;
  td.Width = w; td.Height = h; td.MipLevels = td.ArraySize = 1; td.Format = fmt; td.SampleDesc.Count = 1;
  td.Usage = usage; td.BindFlags = bind; td.CPUAccessFlags = cpu;
  if (FAILED(ID3D11Device_CreateTexture2D(dev, &td, NULL, &t))) { printf("CreateTexture2D failed\n"); exit(1); }
  return t;
}

int main(void) {
  HMODULE dc = LoadLibraryA("d3dcompiler_47.dll");
  compile_fn fn = dc ? (compile_fn)(void *)GetProcAddress(dc, "D3DCompile") : NULL;
  D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0, got;
  ID3D11Device *dev; ID3D11DeviceContext *ctx;
  ID3D11Texture2D *dyn, *rt, *rb, *staging, *dst, *rb2; ID3D11ShaderResourceView *srv; ID3D11RenderTargetView *rtv;
  ID3D11VertexShader *vs; ID3D11PixelShader *ps; ID3D11SamplerState *smp; ID3DBlob *b;
  D3D11_SAMPLER_DESC sd = {0}; D3D11_MAPPED_SUBRESOURCE m;
  int k, x, y, bad_a = 0, bad_b = 0;
  setvbuf(stdout, NULL, _IONBF, 0);
  if (!fn) { printf("no D3DCompile\n"); return 1; }
  if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &fl, 1, D3D11_SDK_VERSION, &dev, &got, &ctx))) {
    printf("D3D11CreateDevice failed\n");
    return 1;
  }
  b = compile(fn, "vs", "vs_5_0");
  ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &vs);
  b = compile(fn, "ps", "ps_5_0");
  ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(b), ID3D10Blob_GetBufferSize(b), NULL, &ps);
  sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT; sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.MaxLOD = D3D11_FLOAT32_MAX;
  ID3D11Device_CreateSamplerState(dev, &sd, &smp);

  /* (a) dynamic texture, a discard before each draw */
  dyn = texture(dev, DW, DH, DXGI_FORMAT_B8G8R8A8_UNORM, D3D11_USAGE_DYNAMIC, D3D11_BIND_SHADER_RESOURCE, D3D11_CPU_ACCESS_WRITE);
  ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)dyn, NULL, &srv);
  rt = texture(dev, DW, ROUNDS * BAND, DXGI_FORMAT_R8G8B8A8_UNORM, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0);
  ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)rt, NULL, &rtv);
  ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
  ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
  ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &smp);
  ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
  for (k = 0; k < ROUNDS; k++) {
    D3D11_VIEWPORT vp = { 0, (float)(k * BAND), DW, BAND, 0, 1 };
    if (FAILED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)dyn, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
      printf("(a) Map(WRITE_DISCARD) failed\n"); return 1;
    }
    for (y = 0; y < DH; y++)
      for (x = 0; x < DW; x++) ((UINT32 *)((BYTE *)m.pData + y * m.RowPitch))[x] = pat(k, x, y);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)dyn, 0);
    ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &srv);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_Draw(ctx, 4, 0);
  }
  rb = texture(dev, DW, ROUNDS * BAND, DXGI_FORMAT_R8G8B8A8_UNORM, D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_READ);
  ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)rb, (ID3D11Resource *)rt);
  ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)rb, 0, D3D11_MAP_READ, 0, &m);
  for (k = 0; k < ROUNDS; k++) {
    const UINT32 *line = (const UINT32 *)((const BYTE *)m.pData + (k * BAND + 1) * m.RowPitch);
    int bad = 0;
    for (x = 0; x < DW; x++) if (line[x] != bgra_to_rgba(pat(k, x, 3))) bad++;
    if (bad) {
      if (!bad_a) printf("(a) band %d: %d of %d pixels wrong; x=5 is %08x, expected %08x\n", k, bad, DW, line[5],
                         bgra_to_rgba(pat(k, 5, 3)));
      bad_a++;
    }
  }
  ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)rb, 0);
  printf("(a) dynamic discard: %d of %d bands wrong\n", bad_a, ROUNDS);

  /* (b) one staging texture reused for every upload */
  staging = texture(dev, SW, SH, DXGI_FORMAT_R8G8B8A8_UNORM, D3D11_USAGE_STAGING, 0,
                    D3D11_CPU_ACCESS_READ | D3D11_CPU_ACCESS_WRITE);
  dst = texture(dev, SW, SH * ROUNDS, DXGI_FORMAT_R8G8B8A8_UNORM, D3D11_USAGE_DEFAULT, D3D11_BIND_SHADER_RESOURCE, 0);
  for (k = 0; k < ROUNDS; k++) {
    D3D11_BOX box = { 0, 0, 0, SW, SH, 1 };
    if (FAILED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_WRITE, 0, &m))) {
      printf("(b) Map(WRITE) failed\n"); return 1;
    }
    for (y = 0; y < SH; y++)
      for (x = 0; x < SW; x++) ((UINT32 *)((BYTE *)m.pData + y * m.RowPitch))[x] = pat(k, x, y);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    ID3D11DeviceContext_CopySubresourceRegion(ctx, (ID3D11Resource *)dst, 0, 0, k * SH, 0, (ID3D11Resource *)staging, 0, &box);
  }
  rb2 = texture(dev, SW, SH * ROUNDS, DXGI_FORMAT_R8G8B8A8_UNORM, D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_READ);
  ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)rb2, (ID3D11Resource *)dst);
  ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)rb2, 0, D3D11_MAP_READ, 0, &m);
  for (k = 0; k < ROUNDS; k++) {
    int bad = 0;
    for (y = 0; y < SH; y++) {
      const UINT32 *line = (const UINT32 *)((const BYTE *)m.pData + (k * SH + y) * m.RowPitch);
      for (x = 0; x < SW; x++) if (line[x] != pat(k, x, y)) bad++;
    }
    if (bad) {
      const UINT32 *line = (const UINT32 *)((const BYTE *)m.pData + (k * SH) * m.RowPitch);
      if (!bad_b) {
        printf("(b) region %d: %d of %d pixels wrong; (0,0) is %08x, expected %08x\n", k, bad, SW * SH, line[0], pat(k, 0, 0));
        for (int s = 0; s < ROUNDS; s++) if (line[0] == pat(s, 0, 0)) printf("    region %d holds upload %d\n", k, s);
      }
      bad_b++;
    }
  }
  ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)rb2, 0);
  printf("(b) staging reuse: %d of %d regions wrong\n", bad_b, ROUNDS);

  if (bad_a || bad_b) { printf("FAIL " NAME "\n"); return 1; }
  printf("PASS " NAME "\n");
  return 0;
}
