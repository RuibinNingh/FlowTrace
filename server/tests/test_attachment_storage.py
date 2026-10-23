import asyncio
import hashlib
import io
from uuid import uuid4

import pytest
from PIL import Image, PngImagePlugin

from flowtrace_server.attachments.images import validate_image
from flowtrace_server.attachments.storage import MAX_BYTES, AttachmentStore
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.persistence.private_files import UnsafeFilePath


def image_bytes(format="PNG", size=(12, 8)):
    output = io.BytesIO()
    image = Image.new("RGB", size, "#3593FD")
    if format == "PNG":
        info = PngImagePlugin.PngInfo()
        info.add_text("private-note", "Never export original financial text")
        image.save(output, format=format, pnginfo=info)
    else:
        image.save(output, format=format)
    return output.getvalue()


async def chunks(data, amount=13):
    for offset in range(0, len(data), amount):
        yield data[offset : offset + amount]


def test_stream_hash_publish_original_and_clean_thumbnail(tmp_path):
    store = AttachmentStore(tmp_path / "private")
    original = image_bytes()
    staged = asyncio.run(
        store.receive(
            uuid4(), chunks(original), len(original), hashlib.sha256(original).hexdigest()
        )
    )
    key = "a" * 64
    info = store.publish(staged, key, "image/png")
    assert (info.width, info.height) == (12, 8)
    assert store.content(key) == original
    with Image.open(io.BytesIO(store.content(key, thumbnail=True))) as thumbnail:
        assert "private-note" not in thumbnail.info
        assert not thumbnail.getexif()
    assert list(store.staging.iterdir()) == []


@pytest.mark.parametrize("case", ["hash", "short", "long", "over-limit", "disconnect"])
def test_invalid_or_interrupted_upload_keeps_no_part_file(tmp_path, case):
    store = AttachmentStore(tmp_path / "private")
    data, size, checksum = b"abc", 3, hashlib.sha256(b"abc").hexdigest()
    if case == "hash":
        checksum = "0" * 64
    elif case == "short":
        size = 4
    elif case == "long":
        size = 2
    elif case == "over-limit":
        data = b"x" * (MAX_BYTES + 1)
        size = MAX_BYTES

    async def interrupted():
        yield b"a"
        raise ConnectionError("synthetic connection loss")

    with pytest.raises((ApiError, ConnectionError)):
        asyncio.run(
            store.receive(
                uuid4(),
                interrupted() if case == "disconnect" else chunks(data, MAX_BYTES + 1),
                size,
                checksum,
            )
        )
    assert list(store.staging.iterdir()) == []


@pytest.mark.parametrize("declared", ["image/jpeg", "image/webp", "text/html"])
def test_real_format_must_match_declaration(tmp_path, declared):
    path = tmp_path / "synthetic.png"
    path.write_bytes(image_bytes())
    with pytest.raises(ApiError) as rejected:
        validate_image(path, declared)
    assert rejected.value.status == 415


def test_decode_dimensions_and_invalid_data_are_rejected(tmp_path):
    path = tmp_path / "synthetic.png"
    path.write_bytes(image_bytes(size=(20, 20)))
    with pytest.raises(ApiError) as rejected:
        validate_image(path, "image/png", max_pixels=399)
    assert rejected.value.code == "image_dimensions"
    path.write_bytes(b"<script>not an image</script>")
    with pytest.raises(ApiError):
        validate_image(path, "image/png")


def test_storage_key_cannot_address_another_file(tmp_path):
    store = AttachmentStore(tmp_path / "private")
    with pytest.raises(ApiError):
        store.object_path("../../secret")
    destination = tmp_path / "outside.txt"
    destination.write_bytes(b"must survive")
    alias = store.object_path("a" * 64)
    try:
        alias.symlink_to(destination)
    except OSError:
        # Windows does not guarantee developer-mode symbolic link permission;
        # a hard link still proves the ordinary-file single-link guard.
        alias.hardlink_to(destination)
    with pytest.raises(UnsafeFilePath):
        store.delete("a" * 64)
    assert destination.read_bytes() == b"must survive"


@pytest.mark.parametrize(
    "format,media_type", [("PNG", "image/png"), ("JPEG", "image/jpeg"), ("WEBP", "image/webp")]
)
def test_all_declared_static_formats_really_decode(tmp_path, format, media_type):
    path = tmp_path / "image.bin"
    path.write_bytes(image_bytes(format=format))
    result = validate_image(path, media_type)
    assert (result.width, result.height) == (12, 8)


def test_truncated_jpeg_and_animated_png_are_not_accepted(tmp_path):
    path = tmp_path / "image.bin"
    path.write_bytes(image_bytes(format="JPEG")[:-20])
    with pytest.raises(ApiError):
        validate_image(path, "image/jpeg")
    first, second = Image.new("RGB", (4, 4), "red"), Image.new("RGB", (4, 4), "blue")
    first.save(path, format="PNG", save_all=True, append_images=[second], duration=100)
    with pytest.raises(ApiError) as rejected:
        validate_image(path, "image/png")
    assert rejected.value.code == "image_animated"


def test_exif_orientation_is_applied_without_exif_in_thumbnail(tmp_path):
    source = Image.new("RGB", (12, 8), "red")
    exif = source.getexif()
    exif[274] = 6
    exif[270] = "private description"
    path = tmp_path / "image.jpg"
    source.save(path, exif=exif)
    result = validate_image(path, "image/jpeg")
    assert (result.width, result.height) == (8, 12)
    with Image.open(io.BytesIO(result.thumbnail)) as image:
        assert image.size == (8, 12) and not image.getexif()
