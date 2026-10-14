// Thin C API over Dear ImGui core + SDL3/Vulkan backends. Pure C (no C++
// types) so Zig @cImport stays clean. Every function is a 1:1 passthrough —
// no engine policy. Ponytail: only the widgets the debug UI uses. Extend per
// widget, not per framework.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque Vulkan/SDL handles (same size as the real pointers/uint64s).
typedef const void *Imgui_VkLoaderFn(const char *name, void *user_data);

// Backend lifecycle. Returns false on failure.
bool Imgui_Init(void *window, void *instance, void *physical_device, void *device,
    uint32_t queue_family, void *queue, void *render_pass, uint32_t image_count,
    Imgui_VkLoaderFn *loader, void *loader_data);
void Imgui_Shutdown(void);
void Imgui_NewFrame(void);
// Record draw data into cmd (call inside the render pass).
void Imgui_Render(void *cmd);
bool Imgui_ProcessEvent(const void *sdl_event);
void Imgui_SetMinImageCount(uint32_t n);

// Immediate-mode UI. Text takes a plain string (format in Zig, no C varargs).
bool Imgui_Begin(const char *name, int flags);
void Imgui_End(void);
void Imgui_Text(const char *str);
bool Imgui_Button(const char *label);
bool Imgui_Checkbox(const char *label, bool *v);
bool Imgui_SliderFloat(const char *label, float *v, float min, float max);
void Imgui_SameLine(void);
void Imgui_Separator(void);
void Imgui_SetNextWindowPos(float x, float y);
void Imgui_SetNextWindowSize(float w, float h);

// IO state.
bool Imgui_WantCaptureMouse(void);
bool Imgui_WantCaptureKeyboard(void);
float Imgui_Framerate(void);

#ifdef __cplusplus
} // extern "C"
#endif
