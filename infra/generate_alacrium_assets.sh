#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
logo="$root/logos/alacrium.svg"
wordmark="$root/logos/alacrium_wordmark.svg"
wordmark_white="$root/logos/alacrium_wordmark_white.svg"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rsvg-convert -w 1024 -h 1024 -o "$tmp/logo.png" "$logo"
rsvg-convert -w 342 -h 64 -o "$tmp/wordmark.png" "$wordmark"
rsvg-convert -w 342 -h 64 -o "$tmp/wordmark-white.png" "$wordmark_white"

render() {
  local size="$1"
  local output="$2"
  magick "$tmp/logo.png" -resize "${size}x${size}" "$output"
}

render_wordmark() {
  local size="$1"
  local source="$2"
  local output="$3"
  magick "$source" -resize "$size" -gravity center -background none -extent "$size" "$output"
}

for size in 16 24 32 48 64 128 256; do
  render "$size" "$root/src/chrome/app/theme/chromium/product_logo_${size}.png"
done

for size in 24 48 64 128 256; do
  render "$size" "$root/src/chrome/app/theme/chromium/linux/product_logo_${size}.png"
done
render 32 "$root/src/chrome/app/theme/chromium/linux/product_logo_32.xpm"

render 16 "$root/src/chrome/app/theme/default_100_percent/chromium/product_logo_16.png"
render 32 "$root/src/chrome/app/theme/default_100_percent/chromium/product_logo_32.png"
render 32 "$root/src/chrome/app/theme/default_200_percent/chromium/product_logo_16.png"
render 64 "$root/src/chrome/app/theme/default_200_percent/chromium/product_logo_32.png"

render 32 "$root/src/chrome/app/theme/chromium/chromeos/chrome_app_icon_32.png"
render 192 "$root/src/chrome/app/theme/chromium/chromeos/chrome_app_icon_192.png"

for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  density="${spec%%:*}"
  size="${spec##*:}"
  render "$size" "$root/src/chrome/android/java/res_chromium_base/mipmap-${density}/app_icon.png"
done

for spec in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
  density="${spec%%:*}"
  size="${spec##*:}"
  render "$size" "$root/src/chrome/android/java/res_chromium_base/mipmap-${density}/layered_app_icon.png"
done

for spec in mdpi:130 hdpi:194 xhdpi:260 xxhdpi:390 xxxhdpi:520; do
  density="${spec%%:*}"
  size="${spec##*:}"
  render "$size" "$root/src/components/browser_ui/styles/android/java/res_chromium/drawable-${density}/fre_product_logo.png"
done

for spec in mdpi:103x21 hdpi:157x32 xhdpi:206x42 xxhdpi:309x63 xxxhdpi:412x84; do
  density="${spec%%:*}"
  size="${spec##*:}"
  render_wordmark "$size" "$tmp/wordmark.png" "$root/src/components/browser_ui/styles/android/java/res_chromium/drawable-${density}/product_logo_name.png"
done

render_wordmark 342x64 "$tmp/wordmark.png" "$root/src/components/resources/default_100_percent/chromium/product_logo.png"
render_wordmark 342x64 "$tmp/wordmark-white.png" "$root/src/components/resources/default_100_percent/chromium/product_logo_white.png"
render_wordmark 342x64 "$tmp/wordmark.png" "$root/src/components/resources/default_200_percent/chromium/product_logo.png"
render_wordmark 342x64 "$tmp/wordmark-white.png" "$root/src/components/resources/default_200_percent/chromium/product_logo_white.png"

render 600 "$root/src/chrome/app/theme/chromium/win/tiles/Logo.png"
render 176 "$root/src/chrome/app/theme/chromium/win/tiles/SmallLogo.png"
render 256 "$root/alacrium_shell/alacrium_shell.png"
cp "$logo" "$root/alacrium_shell/alacrium.svg"

ico_inputs=()
for size in 16 24 32 48 64 128 256; do
  render "$size" "$tmp/icon-${size}.png"
  ico_inputs+=("$tmp/icon-${size}.png")
done

for output in \
  "$root/src/chrome/app/theme/chromium/win/chromium.ico" \
  "$root/src/chrome/app/theme/chromium/win/chromium_doc.ico" \
  "$root/src/chrome/app/theme/chromium/win/chromium_pdf.ico" \
  "$root/src/chrome/installer/mini_installer/mini_installer.ico" \
  "$root/src/chrome/installer/setup/setup.ico" \
  "$root/src/content/shell/app/alacrium_shell.ico" \
  "$root/infra/DEBUG/icons/alacrium_debug_shell.ico" \
  "$root/alacrium_shell/alacrium.ico" \
  "$root/alacrium_shell/alacrium_shell.ico"; do
  magick "${ico_inputs[@]}" "$output"
done

render 22 "$root/infra/APPIMAGE/files/product_logo_22.png"
render 512 "$root/infra/APPIMAGE/files/product_logo_512.png"

for size in 16 24 32 48 64 128 256; do
  render "$size" "$root/infra/DEBUG/icons/icon_${size}.png"
done

# Slot PNGs consumed by infra/build_mac_assets.sh (Assets.car) and logos/NEW/mac/gen/app/build_icns.sh
for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 64x64:64 64x64@2x:128 128x128:128 128x128@2x:256 \
  256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  render "${spec##*:}" "$root/logos/NEW/mac/gen/app/icon_${spec%%:*}.png"
done

for spec in icp4:16 icp5:32 icp6:64 ic07:128 ic08:256 ic09:512 ic10:1024; do
  type="${spec%%:*}"
  size="${spec##*:}"
  render "$size" "$tmp/${type}.png"
done

perl - "$tmp" "$root/src/chrome/app/theme/chromium/mac/app.icns" <<'PERL'
use strict;
use warnings;

my ($source, $output) = @ARGV;
my @types = qw(icp4 icp5 icp6 ic07 ic08 ic09 ic10);
my $body = '';
for my $type (@types) {
  open my $input, '<:raw', "$source/$type.png" or die $!;
  local $/;
  my $png = <$input>;
  close $input;
  $body .= $type . pack('N', length($png) + 8) . $png;
}
open my $icon, '>:raw', $output or die $!;
print {$icon} 'icns', pack('N', length($body) + 8), $body;
close $icon;
PERL

cp "$root/src/chrome/app/theme/chromium/mac/app.icns" \
  "$root/src/chrome/app/theme/chromium/mac/document.icns"
