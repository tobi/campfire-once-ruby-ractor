// In-process libvips for Campfire::Storage::Media: the calls ruby-vips makes for Active Storage
// (the image analyzer, and ImageProcessing::Vips resize_to_limit + format conversion), as
// once-campfire-rust's crates/storage/src/vips.rs does them. One pipeline per call, with no child
// processes or intermediate files. Work runs without the GVL; libvips is thread-safe, and the
// extension is marked Ractor-safe so job Ractors can call it.
#include <ruby.h>
#include <ruby/thread.h>
#include <pthread.h>
#include <vips/vips.h>

#define MAX_COORD 10000000

static VALUE eError;

typedef struct {
  const char *input, *output;
  int width, height;       // MAX_COORD when unbounded
  int resize;              // 0: convert only (autorot + save)
  int img_width, img_height;
  char *orientation;       // g_free'd by the caller
  char *error;             // g_free'd by the caller
} job_t;

// vips_init on first use, as vips.rs does, so boot doesn't pay for loading libvips' modules
// (magick, poppler, heif...). Then the loader restrictions of config/initializers/vips.rb:
// Vips.block_untrusted(true); Vips.block("VipsForeignLoadOpenslide", true).
static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static char *init_error;

static void init_vips(void) {
  if (VIPS_INIT("campfire")) { init_error = vips_error_buffer_copy(); return; }
  vips_block_untrusted_set(TRUE);
  vips_operation_block_set("VipsForeignLoadOpenslide", TRUE);
}

static void take_error(job_t *j) {
  j->error = vips_error_buffer_copy();
  if (!j->error) j->error = g_strdup("libvips error");
}

static int ready(job_t *j) {
  pthread_once(&init_once, init_vips);
  if (init_error) { j->error = g_strdup_printf("vips_init failed: %s", init_error); return 0; }
  return 1;
}

// Vips::Image.new_from_file(path, access: :sequential): width, height and EXIF orientation.
static void *header_nogvl(void *arg) {
  job_t *j = arg;
  if (!ready(j)) return NULL;
  VipsImage *image = vips_image_new_from_file(j->input, "access", VIPS_ACCESS_SEQUENTIAL, NULL);
  if (!image) { take_error(j); return NULL; }
  j->img_width = vips_image_get_width(image);
  j->img_height = vips_image_get_height(image);
  if (vips_image_get_typeof(image, "exif-ifd0-Orientation") != 0) {
    char *s = NULL;
    if (vips_image_get_as_string(image, "exif-ifd0-Orientation", &s) == 0) j->orientation = s;
    else vips_error_clear();
  }
  g_object_unref(image);
  return NULL;
}

// load -> autorot -> [thumbnail_image(w, height:, size: :down, no_rotate: true)
// -> conv(SHARPEN_MASK, precision: :integer)] -> write_to_file (saver from the extension).
static void *resize_nogvl(void *arg) {
  job_t *j = arg;
  VipsImage *image = NULL, *rotated = NULL, *thumb = NULL, *mask = NULL, *sharpened = NULL;
  if (!ready(j)) return NULL;
  if (!(image = vips_image_new_from_file(j->input, NULL))) goto fail;
  if (vips_autorot(image, &rotated, NULL)) goto fail;
  VipsImage *out = rotated;
  if (j->resize) {
    if (vips_thumbnail_image(rotated, &thumb, j->width, "height", j->height, "size", VIPS_SIZE_DOWN,
          "no_rotate", TRUE, NULL)) goto fail;
    static const double values[9] = { -1, -1, -1, -1, 32, -1, -1, -1, -1 };
    if (!(mask = vips_image_new_matrix_from_array(3, 3, values, 9))) goto fail;
    vips_image_set_double(mask, "scale", 24.0);
    vips_image_set_double(mask, "offset", 0.0);
    if (vips_conv(thumb, &sharpened, mask, "precision", VIPS_PRECISION_INTEGER, NULL)) goto fail;
    out = sharpened;
  }
  if (vips_image_write_to_file(out, j->output, NULL)) goto fail;
  goto done;
fail:
  take_error(j);
done:
  if (sharpened) g_object_unref(sharpened);
  if (mask) g_object_unref(mask);
  if (thumb) g_object_unref(thumb);
  if (rotated) g_object_unref(rotated);
  if (image) g_object_unref(image);
  return NULL;
}

static void raise_if_error(job_t *j) {
  if (!j->error) return;
  VALUE msg = rb_str_new_cstr(j->error);
  g_free(j->error);
  g_free(j->orientation);
  rb_exc_raise(rb_exc_new_str(eError, rb_funcall(msg, rb_intern("strip"), 0)));
}

// CampfireVips.header(path) -> [width, height, orientation or nil]
static VALUE m_header(VALUE self, VALUE path) {
  job_t j = { .input = StringValueCStr(path) };
  rb_thread_call_without_gvl(header_nogvl, &j, RUBY_UBF_IO, NULL);
  RB_GC_GUARD(path);
  raise_if_error(&j);
  VALUE orientation = Qnil;
  if (j.orientation) { orientation = rb_str_new_cstr(j.orientation); g_free(j.orientation); }
  return rb_ary_new_from_args(3, INT2NUM(j.img_width), INT2NUM(j.img_height), orientation);
}

// CampfireVips.resize_to_limit(input, output, width, height) -> output. nil width and height:
// convert only. A nil bound is unbounded, as image_processing passes it.
static VALUE m_resize_to_limit(VALUE self, VALUE input, VALUE output, VALUE width, VALUE height) {
  job_t j = { .input = StringValueCStr(input), .output = StringValueCStr(output),
              .resize = !(NIL_P(width) && NIL_P(height)),
              .width = NIL_P(width) ? MAX_COORD : NUM2INT(width),
              .height = NIL_P(height) ? MAX_COORD : NUM2INT(height) };
  rb_thread_call_without_gvl(resize_nogvl, &j, RUBY_UBF_IO, NULL);
  RB_GC_GUARD(input);
  RB_GC_GUARD(output);
  raise_if_error(&j);
  return output;
}

static VALUE m_version(VALUE self) {
  job_t j = { 0 };
  if (!ready(&j)) { raise_if_error(&j); }
  return rb_str_new_cstr(vips_version_string());
}

void Init_campfire_vips(void) {
  rb_ext_ractor_safe(true);
  VALUE m = rb_define_module("CampfireVips");
  eError = rb_define_class_under(m, "Error", rb_eStandardError);
  rb_gc_register_mark_object(eError);
  rb_define_module_function(m, "header", m_header, 1);
  rb_define_module_function(m, "resize_to_limit", m_resize_to_limit, 4);
  rb_define_module_function(m, "version", m_version, 0);
}
