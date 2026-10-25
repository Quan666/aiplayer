#include "my_application.h"
#include "system_proxy.h"

#include <flutter_linux/flutter_linux.h>
#include <cmath>
#include <algorithm>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* main_window;
  FlMethodChannel* desktop_channel;
  SystemProxyHandler* system_proxy;
  bool desktop_ready;
  bool close_requested;
  bool fullscreen;
  bool maximized;
  GtkGesture* drag_gesture;
  GdkEvent* drag_press;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

struct WindowModeState {
  GtkWindow* window;
  bool floating = false;
  bool fullscreen = false;
  bool was_maximized = false;
  int x = 0, y = 0, width = 1280, height = 720;
};

static void exit_floating(WindowModeState* state) {
  if (!state->floating) return;
  state->floating = false;
  gtk_window_set_keep_above(state->window, FALSE);
  gtk_window_resize(state->window, state->width, state->height);
  gtk_window_move(state->window, state->x, state->y);
  if (state->was_maximized) gtk_window_maximize(state->window);
}

static void window_mode_call(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  auto* state = static_cast<WindowModeState*>(data);
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlValue) response = nullptr;
  if (g_strcmp0(method, "supported") == 0) {
    response = fl_value_new_bool(true);
  } else if (g_strcmp0(method, "setVideoFullscreen") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    FlValue* value = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
        ? fl_value_lookup_string(args, "enabled") : nullptr;
    if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
      fl_method_call_respond_error(call, "invalid_arguments", "Missing fullscreen state", nullptr, nullptr);
      return;
    }
    exit_floating(state);
    state->fullscreen = fl_value_get_bool(value);
    if (state->fullscreen) gtk_window_fullscreen(state->window);
    else gtk_window_unfullscreen(state->window);
    response = fl_value_new_bool(state->fullscreen);
  } else if (g_strcmp0(method, "enter") == 0) {
    double ratio = 16.0 / 9;
    FlValue* args = fl_method_call_get_args(call);
    FlValue* value = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
        ? fl_value_lookup_string(args, "aspectRatio") : nullptr;
    if (value && fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) ratio = fl_value_get_float(value);
    if (!std::isfinite(ratio) || ratio <= 0) ratio = 16.0 / 9;
    ratio = std::max(.42, std::min(2.39, ratio));
    if (state->fullscreen) gtk_window_unfullscreen(state->window);
    state->fullscreen = false;
    if (!state->floating) {
      gtk_window_get_position(state->window, &state->x, &state->y);
      gtk_window_get_size(state->window, &state->width, &state->height);
      state->was_maximized = gtk_window_is_maximized(state->window);
    }
    state->floating = true;
    gtk_window_unmaximize(state->window);
    gtk_window_set_keep_above(state->window, TRUE);
    const int height = std::min(540, static_cast<int>(480 / ratio));
    gtk_window_resize(state->window, static_cast<int>(height * ratio), height);
    response = fl_value_new_bool(true);
  } else if (g_strcmp0(method, "exit") == 0) {
    exit_floating(state);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, response, nullptr);
}

static void register_window_mode(FlView* view, GtkWindow* window) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "app.aiplayer/window_mode", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, window_mode_call,
      new WindowModeState{window}, [](gpointer data) {
        delete static_cast<WindowModeState*>(data);
      });
}

static gboolean quit_application(gpointer data) {
  g_application_quit(G_APPLICATION(data));
  return G_SOURCE_REMOVE;
}

static FlValue* desktop_window_state(MyApplication* self) {
  FlValue* state = fl_value_new_map();
  fl_value_set_string_take(state, "fullscreen", fl_value_new_bool(self->fullscreen));
  fl_value_set_string_take(state, "maximized", fl_value_new_bool(self->maximized));
  return state;
}

static gboolean main_window_state(GtkWidget* widget, GdkEventWindowState* event,
                                  gpointer data) {
  auto* self = MY_APPLICATION(data);
  const bool fullscreen = (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
  const bool maximized = (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
  if (self->fullscreen == fullscreen && self->maximized == maximized) return FALSE;
  self->fullscreen = fullscreen;
  self->maximized = maximized;
  if (self->desktop_ready && self->desktop_channel) {
    g_autoptr(FlValue) state = desktop_window_state(self);
    fl_method_channel_invoke_method(self->desktop_channel, "windowStateChanged", state,
        nullptr, nullptr, nullptr);
  }
  return FALSE;
}

static void remember_drag_press(GtkGestureMultiPress* gesture, gint presses,
                                gdouble x, gdouble y, gpointer data) {
  auto* self = MY_APPLICATION(data);
  g_clear_pointer(&self->drag_press, gdk_event_free);
  GdkEventSequence* sequence = gtk_gesture_single_get_current_sequence(GTK_GESTURE_SINGLE(gesture));
  const GdkEvent* event = gtk_gesture_get_last_event(GTK_GESTURE(gesture), sequence);
  if (event && event->type == GDK_BUTTON_PRESS) {
    // The platform channel arrives after GTK's event dispatch. Retain the
    // initiating device and timestamp for the compositor's move request.
    self->drag_press = gdk_event_copy(event);
  }
}

static void forget_drag_press(GtkGestureMultiPress* gesture, gint presses,
                              gdouble x, gdouble y, gpointer data) {
  g_clear_pointer(&MY_APPLICATION(data)->drag_press, gdk_event_free);
}

static void cancel_drag_press(GtkGesture* gesture, GdkEventSequence* sequence,
                              gpointer data) {
  g_clear_pointer(&MY_APPLICATION(data)->drag_press, gdk_event_free);
}

static void start_window_drag(MyApplication* self) {
  if (!self->main_window || !self->drag_press || self->fullscreen) return;
  GdkWindow* window = gtk_widget_get_window(GTK_WIDGET(self->main_window));
  GdkDevice* device = gdk_event_get_device(self->drag_press);
  if (!window || !device) return;
  GdkModifierType buttons;
  gdk_window_get_device_position(window, device, nullptr, nullptr, &buttons);
  if (!(buttons & GDK_BUTTON1_MASK)) return;
  g_autoptr(GdkEvent) press = gdk_event_copy(self->drag_press);
  g_autoptr(GdkEvent) release = gdk_event_copy(self->drag_press);
  release->type = GDK_BUTTON_RELEASE;
  if (const GdkEvent* last = gtk_gesture_get_last_event(self->drag_gesture, nullptr)) {
    release->button.time = gdk_event_get_time(last);
    gdk_event_get_coords(last, &release->button.x, &release->button.y);
    gdk_event_get_root_coords(last, &release->button.x_root, &release->button.y_root);
  }
  // The compositor consumes the real release during its move grab. End the
  // Flutter pointer sequence first, or the first click after moving is lost.
  // Dispatch directly before taking the grab; queuing would end the move itself.
  gtk_main_do_event(release);
  gdk_window_begin_move_drag_for_device(window, device, GDK_BUTTON_PRIMARY,
      static_cast<int>(press->button.x_root), static_cast<int>(press->button.y_root),
      press->button.time);
  g_clear_pointer(&self->drag_press, gdk_event_free);
}

static void desktop_player_call(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  auto* self = MY_APPLICATION(data);
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "getDeviceInfo") == 0) {
    g_autoptr(FlValue) info = fl_value_new_map();
    fl_value_set_string_take(info, "name", fl_value_new_string(g_get_host_name()));
    fl_value_set_string_take(info, "platform", fl_value_new_string("Linux"));
    g_autofree gchar* model = nullptr;
    g_file_get_contents("/sys/class/dmi/id/product_name", &model, nullptr, nullptr);
    fl_value_set_string_take(info, "model", fl_value_new_string(model ? g_strstrip(model) : ""));
    fl_method_call_respond_success(call, info, nullptr);
  } else if (g_strcmp0(method, "ready") == 0) {
    self->desktop_ready = true;
    g_autoptr(FlValue) state = desktop_window_state(self);
    fl_method_call_respond_success(call, state, nullptr);
  } else if (g_strcmp0(method, "startDrag") == 0) {
    start_window_drag(self);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "setControlsVisible") == 0) {
    // The zero-height GTK titlebar has no buttons or caption hit region;
    // Flutter owns visibility and input for the entire window-control strip.
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "minimize") == 0) {
    if (self->main_window) gtk_window_iconify(self->main_window);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "toggleMaximize") == 0) {
    if (self->main_window && !self->fullscreen) {
      if (gtk_window_is_maximized(self->main_window)) gtk_window_unmaximize(self->main_window);
      else gtk_window_maximize(self->main_window);
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "requestClose") == 0) {
    // gtk_window_close emits delete-event, preserving Dart's progress flush.
    fl_method_call_respond_success(call, nullptr, nullptr);
    if (self->main_window) gtk_window_close(self->main_window);
  } else if (g_strcmp0(method, "closeWindow") == 0) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    // Return the channel reply before destroying the main engine.
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, quit_application,
        g_object_ref(self), g_object_unref);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

static gboolean main_delete_event(GtkWidget* widget, GdkEvent* event, gpointer data) {
  auto* self = MY_APPLICATION(data);
  if (!self->desktop_ready) return FALSE;
  if (!self->close_requested) {
    self->close_requested = true;
    fl_method_channel_invoke_method(self->desktop_channel, "closeRequested", nullptr,
        nullptr, nullptr, nullptr);
  }
  return TRUE;
}

static void main_destroyed(GtkWidget* widget, gpointer data) {
  auto* self = MY_APPLICATION(data);
  g_clear_pointer(&self->system_proxy, system_proxy_handler_free);
  g_clear_object(&self->drag_gesture);
  g_clear_pointer(&self->drag_press, gdk_event_free);
  self->main_window = nullptr;
  g_clear_object(&self->desktop_channel);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->main_window) {
    gtk_window_present(self->main_window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->main_window = window;
  g_signal_connect(window, "delete-event", G_CALLBACK(main_delete_event), self);
  g_signal_connect(window, "destroy", G_CALLBACK(main_destroyed), self);
  g_signal_connect(window, "window-state-event", G_CALLBACK(main_window_state), self);

  // Keep GTK client-side decoration for native resize handles and shadows.
  // Only the zero-height titlebar is replaced; Flutter draws the controls over
  // its own background. Undecorating the entire window would lose edge resize.
  gtk_window_set_title(window, "映库");
  GtkWidget* titlebar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_set_name(titlebar, "aiplayer-titlebar");
  g_autoptr(GtkCssProvider) title_style = gtk_css_provider_new();
  gtk_css_provider_load_from_data(title_style,
      "#aiplayer-titlebar { min-height: 0; min-width: 0; padding: 0; "
      "margin: 0; border: 0; background: none; box-shadow: none; }", -1, nullptr);
  gtk_style_context_add_provider(gtk_widget_get_style_context(titlebar),
      GTK_STYLE_PROVIDER(title_style), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  gtk_widget_show(titlebar);
  gtk_window_set_titlebar(window, titlebar);

  // GTK sizes the content independently of the title bar. Fit smaller screens
  // proportionally instead of letting the window manager clip a 720p window.
  int width = 1280;
  int height = 720;
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (!monitor && gdk_display_get_n_monitors(display) > 0) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  if (monitor) {
    GdkRectangle work;
    gdk_monitor_get_workarea(monitor, &work);
    int title_height = 0;
    if (GtkWidget* titlebar = gtk_window_get_titlebar(window)) {
      gtk_widget_get_preferred_height(titlebar, nullptr, &title_height);
    }
    const double scale = std::max(0.0, std::min({1.0,
        (work.width * 0.9 - 16) / width,
        (work.height * 0.9 - std::max(48, title_height)) / height}));
    width = std::max(1, static_cast<int>(std::floor(width * scale)));
    height = std::max(1, static_cast<int>(std::floor(height * scale)));
  }
  gtk_window_set_default_size(window, width, height);
  gtk_window_set_position(window, GTK_WIN_POS_CENTER);
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable != nullptr) {
    g_autofree gchar* directory = g_path_get_dirname(executable);
    g_autofree gchar* icon =
        g_build_filename(directory, "data", "app_icon.png", nullptr);
    gtk_window_set_icon_from_file(window, icon, nullptr);
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  // Flutter consumes the child event box's pointer signals. Observe the
  // capture phase without claiming the gesture so Flutter still receives all
  // clicks, including the double click used to maximize the window.
  self->drag_gesture = gtk_gesture_multi_press_new(GTK_WIDGET(view));
  gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(self->drag_gesture), GDK_BUTTON_PRIMARY);
  gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(self->drag_gesture),
      GTK_PHASE_CAPTURE);
  g_signal_connect(self->drag_gesture, "pressed", G_CALLBACK(remember_drag_press), self);
  g_signal_connect(self->drag_gesture, "released", G_CALLBACK(forget_drag_press), self);
  g_signal_connect(self->drag_gesture, "cancel", G_CALLBACK(cancel_drag_press), self);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#F4F5F7");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  self->system_proxy = system_proxy_handler_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)));
  register_window_mode(view, window);
  g_autoptr(FlStandardMethodCodec) desktop_codec = fl_standard_method_codec_new();
  self->desktop_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "app.aiplayer/desktop_player", FL_METHOD_CODEC(desktop_codec));
  fl_method_channel_set_method_call_handler(self->desktop_channel,
      desktop_player_call, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->system_proxy, system_proxy_handler_free);
  g_clear_object(&self->drag_gesture);
  g_clear_pointer(&self->drag_press, gdk_event_free);
  g_clear_object(&self->desktop_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}

