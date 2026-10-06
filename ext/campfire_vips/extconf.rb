# frozen_string_literal: true

# In-process libvips for Storage::Media (campfire_vips.c). Optional: without libvips' headers the
# build is skipped and Media falls back to the vips CLI.
require "mkmf"

abort "libvips not found (pkg-config vips)" unless pkg_config("vips")
$CFLAGS << " -O2 -Wall -Wno-unused-parameter"
create_makefile("campfire_vips")
