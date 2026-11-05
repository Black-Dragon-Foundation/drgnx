// `lineart` with the weights kept as the 16-bit floats the checkpoint stores; the sum stays f32. Half the VRAM for weights
// and, on the Radeon, 1.4x the speed. kernels.wgsl has the same kernel for an adapter without SHADER_F16.
enable f16;
struct P { t: u32 }
@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> a: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> b: array<vec4<f16>>;
@group(0) @binding(3) var<storage, read_write> c: array<vec4<f32>>;
@group(0) @binding(4) var<storage, read> u: array<vec2<u32>>;

override D_IN: u32 = 4;
override D_OUT: u32 = 4;

@compute @workgroup_size(32)
fn lineart(@builtin(global_invocation_id) id: vec3<u32>) {
  let j4 = id.x; let t = id.y;
  let n_in = D_IN / 4u; let n_out = D_OUT / 4u;
  if (j4 >= n_out || t >= p.t) { return; }
  let xo = t * n_in;
  var r = vec4<f32>(0.0);
  for (var k = 0u; k < n_in; k++) {
    let x = a[xo + k];
    let w = k * 4u * n_out + j4;
    r += x.x * vec4<f32>(b[w]) + x.y * vec4<f32>(b[w + n_out]) + x.z * vec4<f32>(b[w + 2u * n_out]) + x.w * vec4<f32>(b[w + 3u * n_out]);
  }
  c[t * n_out + j4] = r;
}
