import io
from dataclasses import dataclass
from pathlib import Path
from threading import BoundedSemaphore

from PIL import Image, ImageOps, UnidentifiedImageError

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.persistence.private_files import private_open

MEDIA_FORMATS = {"image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WEBP"}
DECODE_SLOTS = BoundedSemaphore(2)


@dataclass(frozen=True)
class ImageInfo:
    width: int
    height: int
    thumbnail: bytes


def validate_image(path: Path, media_type: str, max_pixels: int = 40_000_000) -> ImageInfo:
    if media_type not in MEDIA_FORMATS:
        raise ApiError("image_format", 415)
    if not DECODE_SLOTS.acquire(blocking=False):
        raise ApiError("image_capacity", 503)
    try:
        with (
            private_open(path, path.parent) as binary,
            Image.open(binary, formats=list(MEDIA_FORMATS.values())) as probe,
        ):
            if probe.format != MEDIA_FORMATS[media_type]:
                raise ApiError("image_format", 415)
            if probe.width < 1 or probe.height < 1 or probe.width * probe.height > max_pixels:
                raise ApiError("image_dimensions", 422)
            if getattr(probe, "n_frames", 1) != 1:
                raise ApiError("image_animated", 422)
            probe.verify()
        with (
            private_open(path, path.parent) as binary,
            Image.open(binary, formats=[MEDIA_FORMATS[media_type]]) as source,
        ):
            source.load()  # verify alone does not fully decode JPEG scan data.
            oriented = ImageOps.exif_transpose(source)
            width, height = oriented.size
            oriented.thumbnail((640, 640), Image.Resampling.LANCZOS)
            mode = "RGBA" if "A" in oriented.getbands() else "RGB"
            pixels = oriented.convert(mode)
            clean = Image.new(mode, pixels.size)
            clean.paste(pixels)  # Do not carry EXIF/GPS, ICC or text into the derivative.
            output = io.BytesIO()
            clean.save(output, format="WEBP", quality=82, method=4)
            return ImageInfo(width, height, output.getvalue())
    except ApiError:
        raise
    except Image.DecompressionBombError:
        raise ApiError("image_dimensions", 422) from None
    except (UnidentifiedImageError, OSError, ValueError, SyntaxError):
        raise ApiError("image_invalid", 422) from None
    finally:
        DECODE_SLOTS.release()
