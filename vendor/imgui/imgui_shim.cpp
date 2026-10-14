// C passthrough to Dear ImGui 1.92 + SDL3/Vulkan backends. See imgui_shim.h.
#include "imgui_shim.h"

#include "imgui.h"
#include "backends/imgui_impl_sdl3.h"
#include "backends/imgui_impl_vulkan.h"

bool Imgui_Init(void *window, void *instance, void *physical_device, void *device,
    uint32_t queue_family, void *queue, void *render_pass, uint32_t image_count,
    Imgui_VkLoaderFn *loader, void *loader_data) {
    if (ImGui::CreateContext() == nullptr)
        return false;
    if (!ImGui_ImplSDL3_InitForVulkan((SDL_Window *)window)) {
        ImGui::DestroyContext();
        return false;
    }
    if (!ImGui_ImplVulkan_LoadFunctions(VK_API_VERSION_1_4,
            (PFN_vkVoidFunction(*)(const char *, void *))loader, loader_data)) {
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext();
        return false;
    }
    ImGui_ImplVulkan_InitInfo info{};
    info.ApiVersion = VK_API_VERSION_1_4;
    info.Instance = (VkInstance)instance;
    info.PhysicalDevice = (VkPhysicalDevice)physical_device;
    info.Device = (VkDevice)device;
    info.QueueFamily = queue_family;
    info.Queue = (VkQueue)queue;
    info.DescriptorPoolSize = 64;
    info.MinImageCount = image_count;
    info.ImageCount = image_count;
    info.PipelineInfoMain.RenderPass = (VkRenderPass)render_pass;
    info.PipelineInfoMain.Subpass = 0;
    info.UseDynamicRendering = false;
    if (!ImGui_ImplVulkan_Init(&info)) {
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext();
        return false;
    }
    return true;
}

void Imgui_Shutdown(void) {
    ImGui_ImplVulkan_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
}

void Imgui_NewFrame(void) {
    ImGui_ImplVulkan_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    ImGui::NewFrame();
}

void Imgui_Render(void *cmd) {
    ImGui::Render();
    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)cmd);
}

bool Imgui_ProcessEvent(const void *sdl_event) {
    return ImGui_ImplSDL3_ProcessEvent((const SDL_Event *)sdl_event);
}

void Imgui_SetMinImageCount(uint32_t n) {
    ImGui_ImplVulkan_SetMinImageCount(n);
}

bool Imgui_Begin(const char *name, int flags) {
    return ImGui::Begin(name, nullptr, flags);
}

void Imgui_End(void) {
    ImGui::End();
}

void Imgui_Text(const char *str) {
    ImGui::TextUnformatted(str);
}

bool Imgui_Button(const char *label) {
    return ImGui::Button(label);
}

bool Imgui_Checkbox(const char *label, bool *v) {
    return ImGui::Checkbox(label, v);
}

bool Imgui_SliderFloat(const char *label, float *v, float min, float max) {
    return ImGui::SliderFloat(label, v, min, max);
}

void Imgui_SameLine(void) {
    ImGui::SameLine();
}

void Imgui_Separator(void) {
    ImGui::Separator();
}

void Imgui_SetNextWindowPos(float x, float y) {
    ImGui::SetNextWindowPos(ImVec2(x, y));
}

void Imgui_SetNextWindowSize(float w, float h) {
    ImGui::SetNextWindowSize(ImVec2(w, h));
}

bool Imgui_WantCaptureMouse(void) {
    return ImGui::GetIO().WantCaptureMouse;
}

bool Imgui_WantCaptureKeyboard(void) {
    return ImGui::GetIO().WantCaptureKeyboard;
}

float Imgui_Framerate(void) {
    return ImGui::GetIO().Framerate;
}
