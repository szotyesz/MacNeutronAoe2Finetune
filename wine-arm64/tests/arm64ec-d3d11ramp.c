// A ramp texture updated row by row while it is drawn from, as NoesisGUI draws gradients (aoe2 N3, G-TEXT): each of
// 64 steps writes one row of a 256x16 RGBA8 texture with UpdateSubresource and a one-row box, then draws a band of the
// render target that samples that row (point sampling). Rows are reused four times in the frame, so a draw must see
// the row as it was when the draw was issued, not a later update's data. The bands are read back and compared with
// the pattern each step wrote. Shaders are compiled at run time with d3dcompiler_47.
// Usage: <exe>   Prints "PASS <name>" when every band matches.
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>

#if defined(__x86_64__) && !defined(__arm64ec__)
#define NAME "x64-d3d11ramp"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64ec-d3d11ramp"
#endif

#define W 256
#define ROWS 16
#define STEPS 64
#define BAND 4

typedef HRESULT (WINAPI *compile_fn)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *,
                                     const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

static const char src[] =
  "Texture2D ramp : register(t0); SamplerState smp : register(s0);\n"
  "cbuffer cb : register(b0) { float4 row; };\n"
  "struct V { float4 pos : SV_Position; float2 uv : TEXCOORD0; };\n"
  "V vs(uint id : SV_VertexID) { V o; float2 p = float2((id & 1) ? 1.0 : -1.0, (id & 2) ? -1.0 : 1.0);\n"
  "  o.pos = float4(p, 0, 1); o.uv = float2((p.x + 1) * 0.5, row.x); return o; }\n"
  "float4 ps(V i) : SV_Target { return ramp.SampleLevel(smp, i.uv, 0); }\n";

static UINT32 pattern(int step, int x) {
  return (UINT32)((step * 37 + x) & 0xff) | (UINT32)((step * 101 + 7) & 0xff) << 8 |
         (UINT32)((x * 3 + step * 11) & 0xff) << 16 | 0xff000000u;
}

static ID3DBlob *compile(compile_fn fn, const char *entry, const char *target) {
  ID3DBlob *code = NULL, *errors = NULL;
  if (FAILED(fn(src, sizeof(src) - 1, "ramp", NULL, NULL, entry, target, 0, 0, &code, &errors))) {
    printf("compile %s: %s\n", entry, errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "failed");
    return NULL;
  }
  return code;
}

int main(void) {
  HMODULE dc = LoadLibraryA("d3dcompiler_47.dll");
  compile_fn compile_hlsl = dc ? (compile_fn)(void *)GetProcAddress(dc, "D3DCompile") : NULL;
  D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0, got;
  ID3D11Device *dev; ID3D11DeviceContext *ctx;
  ID3D11Texture2D *ramp, *rt, *readback; ID3D11ShaderResourceView *srv; ID3D11RenderTargetView *rtv;
  ID3D11SamplerState *smp; ID3D11Buffer *cb; ID3D11VertexShader *vs; ID3D11PixelShader *ps;
  ID3DBlob *vsb, *psb;
  D3D11_TEXTURE2D_DESC td = {0}; D3D11_SAMPLER_DESC sd = {0}; D3D11_BUFFER_DESC bd = {0};
  D3D11_MAPPED_SUBRESOURCE m;
  UINT32 row[W];
  int bad_bands = 0, first_bad = -1, step, x;
  setvbuf(stdout, NULL, _IONBF, 0);

  if (!compile_hlsl) { printf("no D3DCompile\n"); return 1; }
  if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &fl, 1, D3D11_SDK_VERSION, &dev, &got, &ctx))) {
    printf("D3D11CreateDevice failed\n");
    return 1;
  }
  if (!(vsb = compile(compile_hlsl, "vs", "vs_5_0")) || !(psb = compile(compile_hlsl, "ps", "ps_5_0"))) return 1;
  ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vsb), ID3D10Blob_GetBufferSize(vsb), NULL, &vs);
  ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(psb), ID3D10Blob_GetBufferSize(psb), NULL, &ps);

  td.Width = W; td.Height = ROWS; td.MipLevels = 1; td.ArraySize = 1; td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  ID3D11Device_CreateTexture2D(dev, &td, NULL, &ramp);
  ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)ramp, NULL, &srv);
  td.Height = STEPS * BAND; td.BindFlags = D3D11_BIND_RENDER_TARGET;
  ID3D11Device_CreateTexture2D(dev, &td, NULL, &rt);
  ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)rt, NULL, &rtv);
  td.BindFlags = 0; td.Usage = D3D11_USAGE_STAGING; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Device_CreateTexture2D(dev, &td, NULL, &readback);
  sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT; sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.MaxLOD = D3D11_FLOAT32_MAX;
  ID3D11Device_CreateSamplerState(dev, &sd, &smp);
  bd.ByteWidth = 16; bd.Usage = D3D11_USAGE_DEFAULT; bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  ID3D11Device_CreateBuffer(dev, &bd, NULL, &cb);

  ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
  ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, &cb);
  ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
  ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &srv);
  ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &smp);
  ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
  for (step = 0; step < STEPS; step++) {
    int r = step % ROWS;
    D3D11_BOX box = { 0, (UINT)r, 0, W, (UINT)r + 1, 1 };
    D3D11_VIEWPORT vp = { 0, (float)(step * BAND), W, BAND, 0, 1 };
    float cbdata[4] = { (r + 0.5f) / ROWS, 0, 0, 0 };
    for (x = 0; x < W; x++) row[x] = pattern(step, x);
    ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)ramp, 0, &box, row, sizeof(row), 0);
    ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)cb, 0, NULL, cbdata, 0, 0);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_Draw(ctx, 4, 0);
  }
  ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)readback, (ID3D11Resource *)rt);
  if (FAILED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)readback, 0, D3D11_MAP_READ, 0, &m))) {
    printf("Map failed\n");
    return 1;
  }
  for (step = 0; step < STEPS; step++) {
    const UINT32 *line = (const UINT32 *)((const BYTE *)m.pData + (size_t)(step * BAND + 1) * m.RowPitch);
    int bad = 0;
    for (x = 0; x < W; x++) if (line[x] != pattern(step, x)) bad++;
    if (bad) {
      if (first_bad < 0) {
        first_bad = step;
        printf("band %d (row %d): %d of %d pixels wrong; x=0 is %08x, expected %08x\n", step, step % ROWS, bad, W,
               line[0], pattern(step, 0));
        for (int s = 0; s < STEPS; s++)
          if (line[0] == pattern(s, 0)) printf("  band %d shows step %d's data\n", step, s);
      }
      bad_bands++;
    }
  }
  ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)readback, 0);
  printf("%d of %d bands wrong\n", bad_bands, STEPS);
  if (bad_bands) {
    printf("FAIL " NAME "\n");
    return 1;
  }
  printf("PASS " NAME "\n");
  return 0;
}
