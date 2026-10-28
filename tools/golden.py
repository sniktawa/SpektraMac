"""Generate golden reference data from Python Spektrafilm for the Swift parity tests.

Run with the interpreter of the pinned Spektrafilm install:

    uv tool install "spektrafilm @ git+https://github.com/andreavolpato/spektrafilm@3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
    ~/.local/share/uv/tools/spektrafilm/bin/python tools/golden.py

Writes golden/<case>/ (gitignored) and golden/manifest.json (committed; sha256 of every file, so a
regeneration that changes anything shows up in `git diff`). With `--out <folder>` it writes there
instead and runs on any Spektrafilm commit (tools/check-upstream.sh).

Inputs
- chart: 256x384 linear ProPhoto RGB (the default input space, no CCTF decoding). Rows 0-63 a grey
  ramp of 24 steps from 0.184*2^-8 to 0.184*2^4; rows 64-191 a 24x8 grid of 16 px patches (24 hues x
  4 saturations x 2 values); rows 192-255 uniform random colours in [0, 1] (seed 20260515).
- photo: scikit-image's `astronaut` (512x512, NASA, public domain) as sRGB-encoded floats in [0, 1],
  fed with input_color_space="sRGB" and input_cctf_decoding=True.

Regimes (stochastic effects are always off: no grain, no glare)
- chart runs with debug.lut_mode=True: a pure per-pixel transform (no spatial effects, no
  auto-exposure, no highlight boost, no scanner corrections). Target for the per-pixel kernels.
- photo runs with the default settings: spatial effects (halation, DIR diffusion, unsharp mask) and
  centre-weighted auto-exposure on. Target for the spatial stages and the end-to-end check.
- preview (Portra 400 -> Portra Endura only) is photo with settings.preview_mode=True, what the GUI's
  preview runs (simulate_preview: the photo is under preview_max_size, so it isn't resized).
- diffusion (Portra 400 -> Portra Endura only) is photo with the diffusion filters on: Black Pro-Mist
  1/2 on the camera with halo warmth +0.3, CineBloom 1/4 on the enlarger with warmth -0.4 (its
  kernel radius capped at half the image).

Pairs: Portra 400 -> Portra Endura, Vision3 500T -> 2383, and scanned directly (scan_film): Velvia 100
(a slide) and Portra 400 (the negative itself). On the chart only (and the QA oracle when printed),
every other film on its own target print, the other slides scanned, and Portra 400 on every other
paper (CHART_PAIRS), so each film and paper is checked end to end.

primitives/ holds per-pixel kernel cases on 64x64x3 float32 inputs, with references computed in
float64 by the Python functions themselves from those same float32 inputs (so only the kernel's
own error shows): curve interpolation (numba fast_interp) on a negative film's exposure axis and on
a positive film's non-monotonic -density axis, log10(max(x, 0) + 1e-10), 10**x and a 3x3 matrix;
and blurs (fast_gaussian_filter, fast_exponential_filter) with per-channel sigmas covering the FIR
path, the IIR path, a mix, and an image smaller than the kernel, with `<name>_sigma` alongside (one
sigma >= 3 for every channel, `blur_equal` and `blur_wide`: an exact Gaussian instead, scipy's
gaussian_filter with replicated edges, since the engine blurs those with Apple's); and each film's
hanatos2025 tc LUT before input gamut compression (`tc_lut_raw_<film>`, 192x192x3); and on that LUT's
own cell grid, the input gamut compression's normalised distance to the spectral locus around D55
and T (`locus_dnorm_<illuminant>`) and matplotlib's inside/outside test (`locus_inside`); highlight
boost (`boost`: boost_ev 2, range 0.3, protect 1) and Portra 400's digested halation + scatter at a
5 um pixel (`halation`, 24 MP scale, so the blurs take the IIR path too); and per printed film the
enlarger light at the digested neutral filters (`enlarger_<film>`), with M +12 / Y -7 shifts
(`enlarger_shifted_<film>`) and the preflash light with M +5 / Y -3 (`preflash_<film>`); and the
Portra chart re-run with print exposure 1.3, exposure compensation +0.7 EV balanced at the
enlarger, and a 0.3 preflash with M +5 / Y -3 (`print_variant_cmy_film`, `print_variant_log_e_print`);
and each paper's print curves from its fitted model, plain (`print_curves_<paper>`) and with every
morph control moved, developer exhaustion 0.4 included (`print_curves_morphed_<paper>`); and CAM16-UCS
as the output gamut compression calls it (L_A 64, Y_b 20, Average surround, the output space's white
at Y = 1), around the sRGB and ProPhoto RGB whites: forward on XYZ of random linear RGB in
[-0.25, 1.5] with a row in [-1, 3] and black, white and 1e-6 grey first (`cam16ucs_xyz_<space>` ->
`cam16ucs_jab_<space>`), and inverse on those J'a'b' with chroma scaled by 0.7 plus a row with J' up
to 130 and |a'|, |b'| up to 100 (`cam16ucs_inverse_jab_<space>` -> `cam16ucs_inverse_xyz_<space>`); and
the cam16ucs output gamut compression for the same two spaces: its C_max(J', h') table
(`cmax_cam16ucs_<space>`, 64x720) and random linear RGB in [-0.3, 1.6] with black, white, 2x white,
1e-6 grey, the primaries and an out-of-gamut red first (`output_compress_x_<space>`), compressed with
the default spec (`output_compress_out_<space>`) and with knee (0.2, 1.1, 4) and no lightness
compression (`output_compress_variant_out_<space>`); and print glare with the default parameters
on a 512x512 frame, blurred (`glare_amount`) and not (`glare_amount_unblurred`), drawn with NumPy's
generator seeded 20260515 in place of numba's; and grain's particle model (`apply_grain` with the
dye-cloud blur, micro-structure and final blur off) at 5 um pixels on 8 uniform density patches of
128x128 (2 % to 98 % of each channel's maximum) for Portra 400 and Velvia 100 (`grain_x_<film>`,
`grain_out_<film>`), drawn with Python's own fixed seeds; and grain complete with the default
parameters: 4 uniform patches of 256x256 at 10/35/60/90 % at 5 um for both films
(`grain_full_x/out_<film>`), for Portra a 512x512 field at 50 % (`grain_field_x/out_<film>`, for
the power spectrum) and a 256x256 one at 0.4 um pixels where the micro-structure is on
(`grain_micro_x/out_<film>`), its lognormal draws from NumPy's generator seeded 20260515; and the
diffusion filter (`apply_diffusion_filter_um`) on a 192x256 dim random field with bright dots and a
bright bar (`diffusion_x`, its own generator seeded 20260515, so the cases above stay as they were),
once per family (`diffusion_<family>_out`): Glimmerglass at strength 0.05 (under the table's first
stop) at 60 um, where the radius stays under the cap and the core is under a pixel; Black Pro-Mist
3/4 (between stops) with halo warmth +0.3 at 5 um, the full-resolution scale; Pro-Mist 1 at spatial
scale 1.5 at 20 um; CineBloom 2 with warmth -0.6 at 40 um.

qa-<film>-<paper>/ holds the LUT creator's QA oracle (spektrafilm_lut_creator.qa.reference, the 50k
random sRGB samples of seed 20260515 through the pipeline in lut_mode, linear in and out) for each
printed pair: the linear input samples after its input gain (samples.npy, 200x250x3), the oracle's output as XYZ the way
its ΔE2000 metric reads it (reference_xyz.npy: encoded, clipped to [0, 1], decoded, to XYZ) and
params.json.

Each case directory holds one float32 .npy per pipeline tap that exists for it (rgb_in, rgb_pre,
log_e_film, cmy_film, [log_e_print, cmy_print,] rgb_out), the filming tc LUT the run used
(tc_lut.npy, 192x192x3), the film density from the run's log_e_film without DIR couplers
(cmy_film_no_couplers.npy, develop_simple on the normalised curves), the scanned RGB before output
gamut compression, blur, unsharp mask and encoding (rgb_uncompressed.npy, the scanning stage's
_density_to_rgb with compression off), that RGB through the run's output gamut compression
(rgb_compressed.npy, from its float32 values), for the Portra chart also the scan of its float32
cmy_print into each other output space (rgb_out_<space>.npy, spaces as file names: DCI-P3,
Display_P3, Adobe_RGB_1998, ITU-R_BT.2020, ProPhoto_RGB, ACES2065-1), and params.json: the digested parameters (profiles by stock name only),
pixel_size_um, the measured auto-exposure EV and the tap list.

raw/patches.dng is not Python's output but an input for the RAW import test: a 512x256 RGGB Bayer
DNG whose camera RGB is linear sRGB (ColorMatrix1 = XYZ -> sRGB, D65), as-shot neutral 1, black 0,
white 65535, baseline exposure 0, with four grey patches at raw 0.05, 0.1, 0.2 and 0.4.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import dataclasses
import hashlib
import json
from importlib.metadata import distribution, version
from pathlib import Path

import colour
import numpy as np
import skimage.data
import tifffile

from spektrafilm import digest_params, init_params
from spektrafilm_lut_creator.bundles import Bundle, BundleSpec
from spektrafilm_lut_creator.color_spaces import to_xyz_qa
from spektrafilm_lut_creator.qa import reference as qa_reference
from spektrafilm.model.develop import develop_simple
from spektrafilm.profiles.io import load_profile
from spektrafilm.model.illuminants import standard_illuminant
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.runtime.services import EnlargerService
from spektrafilm.model import glare as glare_module
from spektrafilm.model import grain as grain_module
from spektrafilm.model.diffusion import apply_diffusion_filter_um, apply_halation_um
from spektrafilm.model.grain import apply_grain
from spektrafilm.runtime.params_schema import DiffusionFilterParams, GlareParams, GrainParams
from spektrafilm.utils import fast_stats
from spektrafilm.utils.numba_boost_hightlights import boost_highlights
from spektrafilm.utils.fast_gaussian_filter import fast_exponential_filter, fast_gaussian_filter
from spektrafilm.utils.fast_interp import fast_interp
from spektrafilm.utils.gamut_compression import OutputGamutCompressSpec, compress_rgb
from spektrafilm.utils.morph_curves import PrintCurvesMorphParams, apply_print_curves_morph
from matplotlib.path import Path as MplPath
from scipy import ndimage
from spektrafilm.utils.gamut_compression import (
    _CAM16UCS_L_A,
    _CAM16UCS_Y_B,
    _get_output_c_max_table,
    _output_cs_whitepoint_xyz,
    _ray_polygon_distance,
    spectral_locus_xy,
)
from spektrafilm.utils.spectral_upsampling import _illuminant_to_xy, _quad2tri, compute_hanatos2025_tc_lut
from spektrafilm.utils.autoexposure import measure_autoexposure_ev

# Spektrafilm isn't on PyPI and its version string doesn't move with `main`, so the reference is the
# git commit it was installed from.
REFERENCE_COMMIT = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
OUT = Path(__file__).resolve().parent.parent / "golden"
OTHER_OUTPUT_SPACES = ["DCI-P3", "Display P3", "Adobe RGB (1998)", "ITU-R BT.2020", "ProPhoto RGB", "ACES2065-1"]


def space_file_name(space: str) -> str:
    return space.replace(" ", "_").replace("(", "").replace(")", "")


PAIRS = [
    ("kodak_portra_400", "kodak_portra_endura", False),
    ("kodak_vision3_500t", "kodak_2383", False),
    # Scanned directly (a slide, and a negative viewed as such); the print profile is required by
    # the API but unused.
    ("fujifilm_velvia_100", "kodak_portra_endura", True),
    ("kodak_portra_400", "kodak_portra_endura", True),
]

# PAIRS and every other film on its own target print, the other slides scanned, and Portra 400 on
# every other paper: on the chart (cheap, the per-pixel lut_mode regime) and the QA oracle only.
CHART_PAIRS = PAIRS + [
    *((film, "fujifilm_crystal_archive_typeii", False)
      for film in ("fujifilm_c200", "fujifilm_pro_400h", "fujifilm_xtra_400")),
    *((film, "kodak_portra_endura", False)
      for film in ("kodak_ektar_100", "kodak_gold_200", "kodak_portra_160", "kodak_portra_800",
                   "kodak_portra_800_push1", "kodak_portra_800_push2", "kodak_ultramax_400")),
    *((film, "kodak_2383", False)
      for film in ("kodak_verita_200d", "kodak_vision3_50d", "kodak_vision3_200t", "kodak_vision3_250d")),
    *((film, "kodak_portra_endura", True)
      for film in ("fujifilm_provia_100f", "kodak_ektachrome_100", "kodak_kodachrome_64")),
    *(("kodak_portra_400", paper, False)
      for paper in ("fujifilm_crystal_archive_typeii", "kodak_ektacolor_edge", "kodak_endura_premier",
                    "kodak_supra_endura", "kodak_ultra_endura", "kodak_2393")),
]


def make_chart() -> np.ndarray:
    chart = np.zeros((256, 384, 3))
    ramp = 0.184 * 2.0 ** np.linspace(-8, 4, 24)
    chart[0:64] = np.repeat(ramp, 16)[None, :, None]

    hues = np.arange(24) / 24
    for row, (saturation, value) in enumerate(
        (s, v) for v in (0.1, 0.6) for s in (0.25, 0.5, 0.75, 1.0)
    ):
        hsv = np.stack([hues, np.full(24, saturation), np.full(24, value)], axis=-1)
        rgb = colour.HSV_to_RGB(hsv)
        y0 = 64 + 16 * row
        chart[y0:y0 + 16] = np.repeat(rgb, 16, axis=0)[None, :, :]

    chart[192:256] = np.random.default_rng(20260515).uniform(0, 1, (64, 384, 3))
    return chart


def make_photo() -> np.ndarray:
    return skimage.data.astronaut().astype(np.float64) / 255


def params_for(film: str, paper: str, scan_film: bool, input_name: str):
    params = init_params(film, paper)
    params.io.scan_film = scan_film
    params.debug.deactivate_stochastic_effects = True
    if input_name == "chart":
        params.debug.lut_mode = True
    else:
        params.io.input_color_space = "sRGB"
        params.io.input_cctf_decoding = True
    params.settings.preview_mode = input_name == "preview"
    if input_name == "diffusion":
        params.camera.diffusion_filter = DiffusionFilterParams(active=True, filter_family="black_pro_mist",
                                                               strength=0.5, halo_warmth=0.3)
        params.enlarger.diffusion_filter = DiffusionFilterParams(active=True, filter_family="cinebloom",
                                                                 strength=0.25, halo_warmth=-0.4)
    return digest_params(params)


def write_raw_patches(path: Path):
    """The Bayer DNG described in the module docstring (tifffile writes the TIFF; the DNG tags are
    extra tags, and PhotometricInterpretation is patched to CFA afterwards)."""
    width, height = 512, 256
    data = np.zeros((height, width), np.uint16)
    for i, value in enumerate([0.05, 0.1, 0.2, 0.4]):
        data[:, i * 128:(i + 1) * 128] = round(value * 65535)

    def srationals(values):
        return [part for value in values for part in (round(value * 10000), 10000)]

    xyz_to_srgb = colour.RGB_COLOURSPACES["sRGB"].matrix_XYZ_to_RGB.flatten()
    tags = [
        (254, "I", 1, 0),                            # NewSubfileType: the main image
        (271, "s", 0, "SpektraMac"),                 # Make
        (272, "s", 0, "Test Camera"),                # Model
        (274, "H", 1, 1),                            # Orientation
        (33421, "H", 2, (2, 2)),                     # CFARepeatPatternDim
        (33422, "B", 4, (0, 1, 1, 2)),               # CFAPattern: RGGB
        (50706, "B", 4, (1, 4, 0, 0)),               # DNGVersion
        (50707, "B", 4, (1, 1, 0, 0)),               # DNGBackwardVersion
        (50708, "s", 0, "SpektraMac Test Camera"),   # UniqueCameraModel
        (50710, "B", 3, (0, 1, 2)),                  # CFAPlaneColor
        (50711, "H", 1, 1),                          # CFALayout: rectangular
        (50714, "H", 1, 0),                          # BlackLevel
        (50717, "I", 1, 65535),                      # WhiteLevel
        (50719, "I", 2, (0, 0)),                     # DefaultCropOrigin
        (50720, "I", 2, (width, height)),            # DefaultCropSize
        (50721, "2i", 9, srationals(xyz_to_srgb)),   # ColorMatrix1
        (50728, "2I", 3, [10000, 10000] * 3),        # AsShotNeutral
        (50730, "2i", 1, [0, 1]),                    # BaselineExposure
        (50778, "H", 1, 21),                         # CalibrationIlluminant1: D65
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    tifffile.imwrite(path, data, photometric="minisblack", metadata=None, software="SpektraMac",
                     extratags=[(*tag, True) for tag in tags])
    with tifffile.TiffFile(path) as tif:
        offset = tif.pages[0].tags[262].valueoffset
    with open(path, "r+b") as file:
        file.seek(offset)
        file.write(np.uint16(32803).tobytes())


def run_all_taps(pipeline: SimulationPipeline, image: np.ndarray) -> dict[str, np.ndarray]:
    # Same walk as runtime.topology.run_topology, but keeping every tap instead of one.
    state = {"rgb_in": image}
    for node in pipeline._topology:
        if all(k in state for k in node.reads):
            node.fire(state)
    return state


def to_jsonable(value):
    if dataclasses.is_dataclass(value):
        return {f.name: to_jsonable(getattr(value, f.name)) for f in dataclasses.fields(value)}
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, (np.floating, np.integer, np.bool_)):
        return value.item()
    if isinstance(value, (tuple, list)):
        return [to_jsonable(v) for v in value]
    return value


@contextlib.contextmanager
def lognormal_from_numpy():
    """Python's lognormal draws (glare, grain micro-structure) from NumPy's global generator, which
    np.random.seed reaches, instead of numba's per-thread one, which it doesn't: reproducible."""
    saved = (glare_module.fast_lognormal_from_mean_std, grain_module.fast_lognormal_from_mean_std,
             fast_stats.fast_lognormal)
    glare_module.fast_lognormal_from_mean_std = fast_stats.fast_lognormal_from_mean_std.py_func
    grain_module.fast_lognormal_from_mean_std = fast_stats.fast_lognormal_from_mean_std.py_func
    fast_stats.fast_lognormal = fast_stats.fast_lognormal.py_func
    try:
        yield
    finally:
        (glare_module.fast_lognormal_from_mean_std, grain_module.fast_lognormal_from_mean_std,
         fast_stats.fast_lognormal) = saved


def params_json(params, **info) -> str:
    """A case's params.json: `info`, then the digested parameters (profiles by stock name only)."""
    info["params"] = {f.name: to_jsonable(getattr(params, f.name))
                      for f in dataclasses.fields(params) if f.name not in ("film", "print")}
    return json.dumps(info, indent=1)


def primitives() -> dict[str, np.ndarray]:
    rng = np.random.default_rng(20260515)

    def image(low, high):
        return rng.uniform(low, high, (64, 64, 3)).astype(np.float32).astype(np.float64)

    arrays = {}
    negative = load_profile("kodak_portra_400").data
    curves = negative.density_curves - np.nanmin(negative.density_curves, axis=0)
    axis = np.tile(negative.log_exposure[:, None], (1, 3)).astype(np.float32).astype(np.float64)
    values = curves.astype(np.float32).astype(np.float64)
    x = image(-3.5, 4.5)
    x[0, :, :] = axis[::4][:64]  # exact nodes: np.interp's right-biased matches
    arrays.update(interp_negative_x=x, interp_negative_axis=axis, interp_negative_values=values,
                  interp_negative_out=fast_interp(x, axis, values))

    positive = load_profile("fujifilm_velvia_100").data
    axis = (-positive.density_curves).astype(np.float32).astype(np.float64)
    values = np.tile(positive.log_exposure[:, None], (1, 3)).astype(np.float32).astype(np.float64)
    x = image(-4.0, 0.5)
    arrays.update(interp_positive_x=x, interp_positive_axis=axis, interp_positive_values=values,
                  interp_positive_out=fast_interp(x, axis, values))

    x = image(-0.5, 20.0)
    x[0, :8, :] = 0.0
    x[1, :8, :] = 1e-12
    arrays.update(log10_x=x, log10_out=np.log10(np.fmax(x, 0.0) + 1e-10))

    x = image(-4.0, 4.0)
    arrays.update(pow10_x=x, pow10_out=10**x)

    matrix = colour.RGB_COLOURSPACES["ProPhoto RGB"].matrix_RGB_to_XYZ.astype(np.float32).astype(np.float64)
    x = image(-0.2, 2.0)
    arrays.update(matmul_x=x, matmul_matrix=matrix, matmul_out=np.einsum("ijk,lk->ijl", x, matrix))

    # Blurs: random pixels (worst case for edges and rounding) on a non-square image.
    blur_cases = {
        "blur_fir": ((96, 128), (0.6, 1.3, 2.9)),
        "blur_iir": ((96, 128), (3.0, 11.0, 40.0)),
        "blur_mixed": ((96, 128), (0.0, 2.0, 7.5)),
        "blur_wide": ((96, 128), (100.0, 100.0, 100.0)),
        "blur_tiny": ((6, 8), (2.9, 1.0, 0.4)),
    }

    def reference_blur(x, sigma):
        # One sigma >= 3 for every channel: the engine runs Apple's Gaussian blur, an exact Gaussian
        # with replicated edges, which fast_gaussian_filter's recursive filter approximates (up to
        # 0.2 off at the borders on these pixels).
        if sigma[0] >= 3 and len(set(sigma)) == 1:
            return ndimage.gaussian_filter(x, (sigma[0], sigma[0], 0), mode="nearest", truncate=8)
        return fast_gaussian_filter(x, np.array(sigma))

    for name, (shape, sigma) in blur_cases.items():
        x = rng.uniform(0, 1, (*shape, 3)).astype(np.float32).astype(np.float64)
        arrays.update({f"{name}_x": x, f"{name}_sigma": np.array(sigma), f"{name}_out": reference_blur(x, sigma)})
    # The smallest sigma Apple's blur takes, on blur_iir's pixels: no new draw, so later arrays keep theirs.
    x = arrays["blur_iir_x"]
    arrays.update(blur_equal_x=x, blur_equal_sigma=np.array((3.0, 3.0, 3.0)),
                  blur_equal_out=reference_blur(x, (3.0, 3.0, 3.0)))
    x = rng.uniform(0, 1, (96, 128, 3)).astype(np.float32).astype(np.float64)
    decay = np.array([2.0, 9.7, 34.0])
    arrays.update(blur_exponential_x=x, blur_exponential_sigma=decay,
                  blur_exponential_out=fast_exponential_filter(x, decay))

    # As FilmingStage builds it with the default settings (window on, surface off, no blur).
    for film in dict.fromkeys(film for film, _, _ in PAIRS):
        profile = load_profile(film)
        adaptation = profile.hanatos2025_adaptation()
        adaptation.apply_window, adaptation.apply_surface = True, False
        sensitivity = np.nan_to_num(10 ** profile.data.log_sensitivity)
        arrays[f"tc_lut_raw_{film}"] = compute_hanatos2025_tc_lut(sensitivity, adaptation, gamut_compress=None)

    # remap_tc_lut_for_compression's cell grid, decoded to xy as it does.
    cells = np.arange(192) / 191
    xy = _quad2tri(np.stack(np.meshgrid(cells, cells, indexing="ij"), axis=-1))
    locus = spectral_locus_xy()
    for illuminant in ("D55", "T"):
        white = _illuminant_to_xy(illuminant)
        delta = xy - white
        dist = np.linalg.norm(delta, axis=-1)
        direction = delta / np.fmax(dist, 1e-12)[..., None]
        boundary = _ray_polygon_distance(white, direction, locus)
        arrays[f"locus_dnorm_{illuminant}"] = dist / np.fmax(boundary, 1e-12)
    arrays["locus_inside"] = MplPath(locus).contains_points(xy.reshape(-1, 2)).reshape(192, 192)

    x = image(0.0, 3.0)
    arrays.update(boost_x=x, boost_out=boost_highlights(x, boost_ev=2.0, boost_range=0.3, protect_ev=1.0))
    halation = digest_params(init_params("kodak_portra_400", "kodak_portra_endura")).film_render.halation
    x = rng.uniform(0, 2, (96, 128, 3)).astype(np.float32).astype(np.float64)
    arrays.update(halation_x=x, halation_out=apply_halation_um(x, halation, 5.0))

    for film, paper, scan_film in PAIRS:
        if scan_film:
            continue
        enlarger = digest_params(init_params(film, paper)).enlarger
        light = standard_illuminant(enlarger.illuminant)
        arrays[f"enlarger_{film}"] = EnlargerService(enlarger).enlarger_filtered_illuminant(light)
        enlarger.m_filter_shift, enlarger.y_filter_shift = 12.0, -7.0
        enlarger.preflash_m_filter_shift, enlarger.preflash_y_filter_shift = 5.0, -3.0
        arrays[f"enlarger_shifted_{film}"] = EnlargerService(enlarger).enlarger_filtered_illuminant(light)
        arrays[f"preflash_{film}"] = EnlargerService(enlarger).preflash_filtered_illuminant(light)

    params = params_for("kodak_portra_400", "kodak_portra_endura", False, "chart")
    params.enlarger.print_exposure = 1.3
    params.enlarger.print_exposure_compensation = True
    params.camera.exposure_compensation_ev = 0.7
    params.enlarger.preflash_exposure = 0.3
    params.enlarger.preflash_m_filter_shift, params.enlarger.preflash_y_filter_shift = 5.0, -3.0
    taps = run_all_taps(SimulationPipeline(params), make_chart())
    arrays.update(print_variant_cmy_film=taps["cmy_film"], print_variant_log_e_print=taps["log_e_print"])

    morph = PrintCurvesMorphParams(active=True, gamma_factor=1.2, gamma_factor_fast=0.9, gamma_factor_slow=1.1,
                                   gamma_factor_red=1.05, gamma_factor_green=0.97, gamma_factor_blue=1.02,
                                   developer_exhaustion=0.4)
    for paper in ("kodak_portra_endura", "kodak_2383"):
        data, kind = load_profile(paper).data, load_profile(paper).info.type
        for name, params in (("print_curves", PrintCurvesMorphParams(active=False)), ("print_curves_morphed", morph)):
            arrays[f"{name}_{paper}"] = apply_print_curves_morph(
                data.log_exposure, data.density_curves_model, params, profile_type=kind)

    # CAM16-UCS exactly as compress_rgb_cam16ucs_chroma calls it, around the output space's white.
    for space in ("sRGB", "ProPhoto RGB"):
        suffix = space.split()[0]
        cam16 = dict(XYZ_w=_output_cs_whitepoint_xyz(space), L_A=_CAM16UCS_L_A, Y_b=_CAM16UCS_Y_B)
        rgb = rng.uniform(-0.25, 1.5, (64, 64, 3))
        rgb[1] = rng.uniform(-1.0, 3.0, (64, 3))
        rgb[0, :3] = [[0.0] * 3, [1.0] * 3, [1e-6] * 3]
        xyz = colour.RGB_to_XYZ(rgb, colourspace=space, illuminant=colour.RGB_COLOURSPACES[space].whitepoint,
                                apply_cctf_decoding=False).astype(np.float32).astype(np.float64)
        jab = colour.XYZ_to_CAM16UCS(xyz, **cam16)
        inverse_jab = jab * [1.0, 0.7, 0.7]
        inverse_jab[1] = rng.uniform([0.0, -100.0, -100.0], [130.0, 100.0, 100.0], (64, 3))
        inverse_jab = inverse_jab.astype(np.float32).astype(np.float64)
        arrays.update({f"cam16ucs_xyz_{suffix}": xyz, f"cam16ucs_jab_{suffix}": jab,
                       f"cam16ucs_inverse_jab_{suffix}": inverse_jab,
                       f"cam16ucs_inverse_xyz_{suffix}": colour.CAM16UCS_to_XYZ(inverse_jab, **cam16)})

    glare = GlareParams()
    with lognormal_from_numpy():
        np.random.seed(20260515)
        arrays["glare_amount"] = glare_module.compute_random_glare_amount(
            glare.percent, glare.roughness, glare.blur, (512, 512))
        arrays["glare_amount_unblurred"] = glare_module.compute_random_glare_amount(
            glare.percent, glare.roughness, 0.0, (512, 512))

    # Grain's particle model (apply_grain, sub-layer model, with Python's own fixed seeds) on uniform
    # patches: 8 density levels from 2 % to 98 % of each channel's maximum, 128 x 128 each, at
    # 5 um pixels; the dye-cloud blur, micro-structure and final blur off.
    particles_only = GrainParams(blur=0.0, blur_dye_clouds_um=0.0, micro_structure=(0.0, 0.0))
    for film in ("kodak_portra_400", "fujifilm_velvia_100"):
        profile = load_profile(film)
        curves = profile.data.density_curves - np.nanmin(profile.data.density_curves, axis=0)
        fractions = np.repeat(np.linspace(0.02, 0.98, 8), 128)
        x = np.tile((fractions[:, None] * np.nanmax(curves, axis=0))[None], (128, 1, 1))
        x = x.astype(np.float32).astype(np.float64)
        arrays[f"grain_x_{film}"] = x
        arrays[f"grain_out_{film}"] = apply_grain(x.copy(), 5.0, particles_only, curves,
                                                  profile.data.density_curves_layers, profile.info.type)

    # Grain complete, default parameters: 4 uniform patches of 256 x 256 (10 %, 35 %, 60 %, 90 % of
    # each channel's maximum) at 5 um pixels for both films; for Portra also a 512 x 512 field at
    # 50 % (power spectrum) and a 256 x 256 one at 0.4 um pixels, where the micro-structure is on.
    with lognormal_from_numpy():
        np.random.seed(20260515)
        for film in ("kodak_portra_400", "fujifilm_velvia_100"):
            profile = load_profile(film)
            curves = profile.data.density_curves - np.nanmin(profile.data.density_curves, axis=0)
            maximum = np.nanmax(curves, axis=0)
            fields = {"full": (np.repeat([0.1, 0.35, 0.6, 0.9], 256), 256, 5.0)}
            if film == "kodak_portra_400":
                fields |= {"field": (np.full(512, 0.5), 512, 5.0), "micro": (np.full(256, 0.5), 256, 0.4)}
            for name, (fractions, rows, pixel_size_um) in fields.items():
                x = np.tile((fractions[:, None] * maximum)[None], (rows, 1, 1)).astype(np.float32).astype(np.float64)
                arrays[f"grain_{name}_x_{film}"] = x
                arrays[f"grain_{name}_out_{film}"] = apply_grain(
                    x.copy(), pixel_size_um, GrainParams(), curves, profile.data.density_curves_layers,
                    profile.info.type)

    # Output gamut compression (cam16ucs): the C_max(J', h') table and compressed samples.
    for space in ("sRGB", "ProPhoto RGB"):
        suffix = space.split()[0]
        arrays[f"cmax_cam16ucs_{suffix}"] = _get_output_c_max_table("cam16ucs", space)[2]
        x = rng.uniform(-0.3, 1.6, (64, 64, 3))
        x[0, :8] = [[0, 0, 0], [1, 1, 1], [2, 2, 2], [1e-6] * 3, [1, 0, 0], [0, 1, 0], [0, 0, 1], [1.2, -0.1, -0.1]]
        x = x.astype(np.float32).astype(np.float64)
        variant = OutputGamutCompressSpec(knee=(0.2, 1.1, 4.0), lightness_compression=None)
        arrays.update({f"output_compress_x_{suffix}": x,
                       f"output_compress_out_{suffix}": compress_rgb(x, OutputGamutCompressSpec(), output_color_space=space),
                       f"output_compress_variant_out_{suffix}": compress_rgb(x, variant, output_color_space=space)})

    diffusion_rng = np.random.default_rng(20260515)
    x = diffusion_rng.uniform(0, 0.3, (192, 256, 3))
    x[diffusion_rng.integers(0, 192, 12), diffusion_rng.integers(0, 256, 12)] = 40.0
    x[90:94, 40:200] = [12.0, 9.0, 6.0]
    x = x.astype(np.float32).astype(np.float64)
    arrays["diffusion_x"] = x
    for family, strength, extra, pixel_size_um in [("glimmerglass", 0.05, {}, 60.0),
                                                   ("black_pro_mist", 0.75, {"halo_warmth": 0.3}, 5.0),
                                                   ("pro_mist", 1.0, {"spatial_scale": 1.5}, 20.0),
                                                   ("cinebloom", 2.0, {"halo_warmth": -0.6}, 40.0)]:
        params = DiffusionFilterParams(active=True, filter_family=family, strength=strength, **extra)
        arrays[f"diffusion_{family}_out"] = apply_diffusion_filter_um(x, params, pixel_size_um)
    return arrays


def installed_commit() -> str | None:
    """The commit in the install's direct_url.json (PEP 610); None unless it came from git."""
    direct_url = distribution("spektrafilm").read_text("direct_url.json")
    if direct_url is None:
        return None
    return json.loads(direct_url).get("vcs_info", {}).get("commit_id")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, help="write here instead, from any Spektrafilm commit (tools/check-upstream.sh)")
    args = parser.parse_args()
    out = args.out or OUT
    installed = installed_commit()
    if args.out is None and installed != REFERENCE_COMMIT:
        raise SystemExit(f"Need spektrafilm at commit {REFERENCE_COMMIT}, found {installed or 'an install not from git'}")

    inputs = {"chart": make_chart(), "photo": make_photo(), "preview": make_photo(), "diffusion": make_photo()}
    manifest = {
        "spektrafilmCommit": installed,
        "versions": {name: version(name) for name in ("numpy", "scipy", "colour-science", "scikit-image")},
        "files": {},
    }

    for film, paper, scan_film in CHART_PAIRS:
        for input_name, image in inputs.items():
            if input_name != "chart" and (film, paper, scan_film) not in PAIRS:
                continue
            if input_name in ("preview", "diffusion") and (film, paper, scan_film) != PAIRS[0]:
                continue
            case = f"{input_name}-{film}-{'scan' if scan_film else paper}"
            params = params_for(film, paper, scan_film, input_name)
            pipeline = SimulationPipeline(params)
            taps = run_all_taps(pipeline, image)

            # The exact value the pipeline applies in preprocess (0 when auto-exposure is off).
            autoexposure_ev = 0.0
            if params.camera.auto_exposure:
                autoexposure_ev = measure_autoexposure_ev(
                    pipeline._resize_service.small_preview(image),
                    params.io.input_color_space,
                    params.io.input_cctf_decoding,
                    method=params.camera.auto_exposure_method,
                )

            case_dir = out / case
            case_dir.mkdir(parents=True, exist_ok=True)
            curves = params.film.data.density_curves
            no_couplers = develop_simple(taps["log_e_film"], params.film.data.log_exposure,
                                         curves - np.nanmin(curves, axis=0),
                                         gamma_factor=params.film_render.density_curve_gamma)
            uncompressed_params = copy.deepcopy(params)
            uncompressed_params.io.output_gamut_compress = OutputGamutCompressSpec(algorithm="off")
            scanner = SimulationPipeline(uncompressed_params)._scanning_stage
            uncompressed = scanner._density_to_rgb(taps["cmy_film" if scan_film else "cmy_print"], use_lut=False)
            # From the float32 values the Swift tests read, so both sides compress the same input.
            compressed = compress_rgb(np.float32(uncompressed).astype(np.float64), params.io.output_gamut_compress,
                                      output_color_space=params.io.output_color_space)
            arrays = dict(taps, tc_lut=pipeline._lut_service.filming_tc_lut_memory,
                          cmy_film_no_couplers=no_couplers, rgb_uncompressed=uncompressed,
                          rgb_compressed=compressed)
            if case == "chart-kodak_portra_400-kodak_portra_endura":
                # The scan into every other output space, from the float32 cmy_print.
                for space in OTHER_OUTPUT_SPACES:
                    variant = copy.deepcopy(params)
                    variant.io.output_color_space = space
                    scanner = SimulationPipeline(variant)._scanning_stage
                    arrays[f"rgb_out_{space_file_name(space)}"] = scanner.scan(
                        np.float32(taps["cmy_print"]).astype(np.float64))
            for name, array in arrays.items():
                np.save(case_dir / f"{name}.npy", np.asarray(array, dtype=np.float32))

            (case_dir / "params.json").write_text(params_json(
                params, film=film, print=None if scan_film else paper, input=input_name,
                regime={"chart": "lut_mode", "preview": "preview_mode"}.get(input_name, "default"), taps=list(taps),
                pixel_size_um=pipeline._resize_service.pixel_size_um, autoexposure_ev=float(autoexposure_ev)))

            for path in sorted(case_dir.iterdir()):
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                manifest["files"][f"{case}/{path.name}"] = digest
            print(f"{case}: {', '.join(taps)}")

    # The LUT creator's QA oracle for each printed pair: its 50k random sRGB samples through the
    # pipeline in lut_mode, linear in and out (qa.reference._compute with the default bundle spec:
    # the samples carry its input gain, white 4 stops over grey; the SDR output's gain is 1).
    for film, paper, scan_film in CHART_PAIRS:
        if scan_film:
            continue
        spec = BundleSpec(film_profile=film, print_profiles=(paper,), input_color_space="sRGB",
                          output_color_space="sRGB")
        frame = spec.bake_frame()
        assert frame.output_gain == 1
        oracle = qa_reference._compute(spec, Bundle(), 0, n_samples=qa_reference.DEFAULT_OFFGRID_SAMPLES,
                                       rng_seed=qa_reference.DEFAULT_RNG_SEED)
        # Its params, rebuilt as it builds them; checked by rerunning.
        params = init_params(film, paper)
        params.debug.lut_mode = True
        params.io.input_color_space = params.io.output_color_space = "sRGB"
        params.io.input_cctf_decoding = params.io.output_cctf_encoding = False
        params = digest_params(params)
        pipeline = SimulationPipeline(params)
        rerun = np.asarray(pipeline.process(oracle.rng_samples_linear.reshape(1, -1, 3)), dtype=float)
        assert np.array_equal(rerun.reshape(-1, 3), oracle.pipeline_out_linear)

        case = f"qa-{film}-{paper}"
        case_dir = out / case
        case_dir.mkdir(parents=True, exist_ok=True)
        np.save(case_dir / "samples.npy", oracle.rng_samples_linear.reshape(200, 250, 3))
        np.save(case_dir / "reference_xyz.npy",
                np.float32(to_xyz_qa(oracle.pipeline_out_encoded, "sRGB")).reshape(200, 250, 3))
        (case_dir / "params.json").write_text(params_json(
            params, film=film, print=paper, input="qa", regime="lut_mode", taps=[],
            pixel_size_um=pipeline._resize_service.pixel_size_um, autoexposure_ev=0.0))
        for path in sorted(case_dir.iterdir()):
            manifest["files"][f"{case}/{path.name}"] = hashlib.sha256(path.read_bytes()).hexdigest()
        print(f"{case}: {len(oracle.rng_samples_linear)} samples")

    primitives_dir = out / "primitives"
    primitives_dir.mkdir(parents=True, exist_ok=True)
    for name, array in primitives().items():
        path = primitives_dir / f"{name}.npy"
        np.save(path, np.asarray(array, dtype=np.float32))
        manifest["files"][f"primitives/{path.name}"] = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"primitives: {len(list(primitives_dir.iterdir()))} arrays")

    raw_path = out / "raw" / "patches.dng"
    write_raw_patches(raw_path)
    manifest["files"]["raw/patches.dng"] = hashlib.sha256(raw_path.read_bytes()).hexdigest()
    print("raw: patches.dng")

    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
