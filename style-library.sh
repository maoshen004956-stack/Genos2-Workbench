# Used by arrange and build-workbench. The caller sets folder to the project root.
if [ -n "${GENOS2_STYLE_LIBRARY:-}" ]; then
    style_library="$GENOS2_STYLE_LIBRARY"
elif [ -n "${YAMAHA_PROJECT:-}" ]; then
    style_library="$YAMAHA_PROJECT/Genos2"
elif [ -d "$folder/Genos2" ]; then
    style_library="$folder/Genos2"
else
    style_library="$folder/../yamaha-sx900/Genos2"
fi

if [ ! -d "$style_library" ]; then
    printf '找不到 Genos2 风格曲库。请用 GENOS2_STYLE_LIBRARY 指定曲库目录。\n' >&2
    exit 1
fi
