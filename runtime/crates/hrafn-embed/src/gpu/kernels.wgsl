// ModernBERT's forward pass as compute kernels. Tokens are flat, with no padding: token t of the batch is row t, and the
// softmax is streamed, so no S x S matrix exists at any point.
// net.rs prepends the model's shape as constants, because WGSL sizes a function's arrays with constants only:
//   HID (hidden size in vec4s), HID_F (hidden size in floats), HEADS, HV (a head in vec4s), GLU (intermediate size in
//   vec4s), SCALE (1 / sqrt(head size)), EPS (LayerNorm's).
struct P { t: u32 }
@group(0) @binding(0) var<uniform> p: P;
@group(0) @binding(1) var<storage, read> a: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> b: array<vec4<f32>>;
@group(0) @binding(3) var<storage, read_write> c: array<vec4<f32>>;
@group(0) @binding(4) var<storage, read> u: array<vec2<u32>>;   // per token: its position, or its attention span

override D_IN: u32 = 4;
override D_OUT: u32 = 4;

// c = a * W, with W transposed (input x output) so all outputs of a token walk one weight row together. The threads then
// share cache lines of both x and W. One invocation = 4 outputs.
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
    r += x.x * b[w] + x.y * b[w + n_out] + x.z * b[w + 2u * n_out] + x.w * b[w + 3u * n_out];
  }
  c[t * n_out + j4] = r;
}

// LayerNorm without bias: c = (a - mean) / sqrt(var + eps) * gain
@compute @workgroup_size(32)
fn norm(@builtin(global_invocation_id) id: vec3<u32>) {
  let t = id.x;
  if (t >= p.t) { return; }
  let o = t * HID;
  var s = 0.0;
  var q = 0.0;
  for (var k = 0u; k < HID; k++) {
    let v = a[o + k];
    s += v.x + v.y + v.z + v.w;
    q += dot(v, v);
  }
  let m = s / HID_F;
  let f = 1.0 / sqrt(q / HID_F - m * m + EPS);
  for (var k = 0u; k < HID; k++) {
    c[o + k] = (a[o + k] - vec4<f32>(m)) * f * b[k];
  }
}

// In place on q and k of qkv (q, k, v, each HID vec4s; each of HEADS heads of HV). a = the cos/sin table, u.x = position.
// x_lo' = lo cos - hi sin; x_hi' = hi cos + lo sin (rope = x cos + rotate_half(x) sin)
@compute @workgroup_size(32)
fn rope(@builtin(global_invocation_id) id: vec3<u32>) {
  let t = id.x; let h = id.y;
  if (t >= p.t) { return; }
  let half_head = HV / 2u;
  let pos = u[t].x;
  for (var part = 0u; part < 2u; part++) {
    let o = t * 3u * HID + part * HID + h * HV;
    for (var k = 0u; k < half_head; k++) {
      let co = a[pos * HV + k];
      let si = a[pos * HV + half_head + k];
      let lo = c[o + k];
      let hi = c[o + half_head + k];
      c[o + k] = lo * co - hi * si;
      c[o + half_head + k] = hi * co + lo * si;
    }
  }
}

// One row of one head: scores against the token's span, softmax, weighted sum of v. The running maximum rescales the sums,
// so the softmax needs no row of scores. a = qkv, c = out, u = the span.
@compute @workgroup_size(32)
fn attn(@builtin(workgroup_id) g: vec3<u32>, @builtin(local_invocation_id) l: vec3<u32>) {
  let h = g.x; let t = g.y * 32u + l.x;
  if (t >= p.t) { return; }
  var q: array<vec4<f32>, HV>;
  var num: array<vec4<f32>, HV>;
  let qo = t * 3u * HID + h * HV;
  for (var k = 0u; k < HV; k++) { q[k] = a[qo + k]; num[k] = vec4<f32>(0.0); }
  let span = u[t];
  var m = 0.0;
  var den = 0.0;
  for (var j = span.x; j < span.y; j++) {
    let ko = j * 3u * HID + HID + h * HV;
    var s = 0.0;
    for (var k = 0u; k < HV; k++) { s += dot(q[k], a[ko + k]); }
    s *= SCALE;
    if (j == span.x) {
      m = s;
    } else if (s > m) {
      let r = exp(m - s);
      den *= r;
      for (var k = 0u; k < HV; k++) { num[k] *= r; }
      m = s;
    }
    let e = exp(s - m);
    den += e;
    let vo = j * 3u * HID + 2u * HID + h * HV;
    for (var k = 0u; k < HV; k++) { num[k] += a[vo + k] * e; }
  }
  let o = t * HID + h * HV;
  for (var k = 0u; k < HV; k++) { c[o + k] = num[k] / den; }
}

fn erf(v: vec4<f32>) -> vec4<f32> {   // Abramowitz & Stegun 7.1.28, |error| <= 3e-7
  let x = abs(v);
  let y = 1.0 + x * (0.0705230784 + x * (0.0422820123 + x * (0.0092705272 + x * (0.0001520143 + x * (0.0002765672 + x * 0.0000430638)))));
  let y2 = y * y; let y4 = y2 * y2; let y8 = y4 * y4; let y16 = y8 * y8;
  return sign(v) * (1.0 - 1.0 / y16);
}

// GeGLU: a holds [x; g], GLU vec4s each; c = gelu(x) * g
@compute @workgroup_size(32)
fn glu(@builtin(global_invocation_id) id: vec3<u32>) {
  let t = id.x;
  if (t >= p.t) { return; }
  for (var k = 0u; k < GLU; k++) {
    let x = a[t * 2u * GLU + k];
    let g = a[t * 2u * GLU + GLU + k];
    c[t * GLU + k] = 0.5 * x * (1.0 + erf(x * 0.7071067811865476)) * g;
  }
}

// c += a
@compute @workgroup_size(32)
fn add(@builtin(global_invocation_id) id: vec3<u32>) {
  let t = id.x;
  if (t >= p.t) { return; }
  for (var k = 0u; k < HID; k++) { c[t * HID + k] += a[t * HID + k]; }
}
