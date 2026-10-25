param(
    [string]$ProjectDirectory = (Join-Path $PSScriptRoot '../..'),
    [string]$OutputDirectory,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$ProjectDirectory = (Resolve-Path -LiteralPath $ProjectDirectory).Path
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $ProjectDirectory '../../outputs/branding/flow-f'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$sourcePath = Join-Path $ProjectDirectory 'assets/branding/flowtrace-icon.png'
Add-Type -AssemblyName System.Drawing
if (-not ('FlowTraceIconExport' -as [type])) {
    $drawingReferences = @([Drawing.Image].Assembly.Location, [Drawing.Color].Assembly.Location) | Select-Object -Unique
    # Newer .NET Windows drawing assemblies expose GDI interfaces from these dependencies.
    $drawingDirectory = Split-Path -Parent ([Drawing.Graphics].Assembly.Location)
    $drawingReferences = @($drawingReferences) + @(Get-ChildItem -LiteralPath $drawingDirectory -Filter 'System.Private.Windows.*.dll' | Select-Object -ExpandProperty FullName)
    Add-Type -ReferencedAssemblies $drawingReferences -TypeDefinition @'
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class FlowTraceIconExport {
    private static Bitmap Render(Image source, int size, double padding) {
        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        using (var attributes = new ImageAttributes()) {
            g.CompositingMode = CompositingMode.SourceCopy;
            g.CompositingQuality = CompositingQuality.HighQuality;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            attributes.SetWrapMode(WrapMode.TileFlipXY);
            int p = (int)Math.Round(size * padding);
            int inner = size - 2 * p;
            int w = source.Width, h = source.Height;
            if (p > 0) {
                // Extend only the outermost background pixels into the padding.
                // The selected artwork is resized intact in the center.
                g.DrawImage(source, new Rectangle(0, 0, p, p), 0, 0, 1, 1, GraphicsUnit.Pixel, attributes);
                g.DrawImage(source, new Rectangle(size-p, 0, p, p), w-1, 0, 1, 1, GraphicsUnit.Pixel, attributes);
                g.DrawImage(source, new Rectangle(0, size-p, p, p), 0, h-1, 1, 1, GraphicsUnit.Pixel, attributes);
                g.DrawImage(source, new Rectangle(size-p, size-p, p, p), w-1, h-1, 1, 1, GraphicsUnit.Pixel, attributes);
                g.DrawImage(source, new Rectangle(p, 0, inner, p), 0, 0, w, 1, GraphicsUnit.Pixel, attributes);
                g.DrawImage(source, new Rectangle(p, size-p, inner, p), 0, h-1, w, 1, GraphicsUnit.Pixel, attributes);
                g.DrawImage(source, new Rectangle(0, p, p, inner), 0, 0, 1, h, GraphicsUnit.Pixel, attributes);
                g.DrawImage(source, new Rectangle(size-p, p, p, inner), w-1, 0, 1, h, GraphicsUnit.Pixel, attributes);
            }
            g.DrawImage(source, new Rectangle(p, p, inner, inner), 0, 0, w, h, GraphicsUnit.Pixel, attributes);
        }
        return bitmap;
    }

    public static void Png(string sourcePath, string targetPath, int size, double padding) {
        Directory.CreateDirectory(Path.GetDirectoryName(targetPath));
        using (var source = Image.FromFile(sourcePath))
        using (var bitmap = Render(source, size, padding)) {
            bitmap.Save(targetPath, ImageFormat.Png);
        }
    }

    private static byte[] IconFrame(Bitmap bitmap, bool png) {
        using (var stream = new MemoryStream()) {
            if (png) {
                bitmap.Save(stream, ImageFormat.Png);
            } else {
                using (var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, true)) {
                    int size = bitmap.Width;
                    int maskStride = ((size + 31) / 32) * 4;
                    writer.Write((uint)40);
                    writer.Write(size);
                    writer.Write(size * 2);
                    writer.Write((ushort)1);
                    writer.Write((ushort)32);
                    writer.Write((uint)0);
                    writer.Write((uint)(size * size * 4 + maskStride * size));
                    writer.Write(0); writer.Write(0); writer.Write(0); writer.Write(0);
                    for (int y = size - 1; y >= 0; y--) {
                        for (int x = 0; x < size; x++) {
                            Color c = bitmap.GetPixel(x, y);
                            writer.Write(c.B); writer.Write(c.G); writer.Write(c.R); writer.Write(c.A);
                        }
                    }
                    writer.Write(new byte[maskStride * size]);
                }
            }
            return stream.ToArray();
        }
    }

    public static void Ico(string sourcePath, string targetPath) {
        int[] sizes = {16, 24, 32, 48, 64, 128, 256};
        byte[][] frames = new byte[sizes.Length][];
        using (var source = Image.FromFile(sourcePath)) {
            for (int i = 0; i < sizes.Length; i++) {
                using (var bitmap = Render(source, sizes[i], 0)) {
                    frames[i] = IconFrame(bitmap, sizes[i] == 256);
                }
            }
        }
        Directory.CreateDirectory(Path.GetDirectoryName(targetPath));
        using (var writer = new BinaryWriter(File.Create(targetPath))) {
            writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)sizes.Length);
            uint offset = (uint)(6 + 16 * sizes.Length);
            for (int i = 0; i < sizes.Length; i++) {
                byte size = (byte)(sizes[i] == 256 ? 0 : sizes[i]);
                writer.Write(size); writer.Write(size); writer.Write((byte)0); writer.Write((byte)0);
                writer.Write((ushort)1); writer.Write((ushort)32);
                writer.Write((uint)frames[i].Length); writer.Write(offset);
                offset += (uint)frames[i].Length;
            }
            foreach (byte[] frame in frames) writer.Write(frame);
        }
    }
}
'@
}

$exports = [Collections.Generic.List[object]]::new()
function Export-Png([string]$RelativePath, [int]$Size, [double]$Padding, [string]$ApplyPath) {
    $target = Join-Path $OutputDirectory $RelativePath
    [FlowTraceIconExport]::Png($sourcePath, $target, $Size, $Padding)
    $exports.Add([ordered]@{
        path = $RelativePath; width = $Size; height = $Size
        padding_per_side = $Padding; apply_path = $ApplyPath
        sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    if ($Apply -and $ApplyPath) {
        $destination = Join-Path $ProjectDirectory $ApplyPath
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        Copy-Item -LiteralPath $target -Destination $destination -Force
    }
}

Export-Png 'flowtrace-icon-1024.png' 1024 0 ''
$densities = [ordered]@{mdpi=48; hdpi=72; xhdpi=96; xxhdpi=144; xxxhdpi=192}
foreach ($density in $densities.GetEnumerator()) {
    $relative = "android/mipmap-$($density.Key)/ic_launcher.png"
    Export-Png $relative $density.Value 0 "android/app/src/main/res/mipmap-$($density.Key)/ic_launcher.png"
}
Export-Png 'web/favicon.png' 32 0 'web/favicon.png'
foreach ($size in @(192, 512)) {
    Export-Png "web/icons/Icon-$size.png" $size 0 "web/icons/Icon-$size.png"
    Export-Png "web/icons/Icon-maskable-$size.png" $size 0.08 "web/icons/Icon-maskable-$size.png"
}
$icoPath = Join-Path $OutputDirectory 'windows/app_icon.ico'
[FlowTraceIconExport]::Ico($sourcePath, $icoPath)
$exports.Add([ordered]@{
    path = 'windows/app_icon.ico'; sizes = @(16,24,32,48,64,128,256)
    apply_path = 'windows/runner/resources/app_icon.ico'
    sha256 = (Get-FileHash -LiteralPath $icoPath -Algorithm SHA256).Hash.ToLowerInvariant()
})
if ($Apply) {
    Copy-Item -LiteralPath $icoPath -Destination (Join-Path $ProjectDirectory 'windows/runner/resources/app_icon.ico') -Force
}
$manifest = [ordered]@{
    design = '流线 F'; source = 'assets/branding/flowtrace-icon.png'
    source_sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    renderer = 'Windows System.Drawing / HighQualityBicubic'
    exports = $exports
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'manifest.json') -Encoding utf8
if ($Apply) {
    Copy-Item -LiteralPath (Join-Path $OutputDirectory 'manifest.json') -Destination (Join-Path $ProjectDirectory 'assets/branding/icon-manifest.json') -Force
}
Write-Output "Exported $($exports.Count) assets to $OutputDirectory (Apply=$Apply)."
