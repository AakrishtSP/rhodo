// Dear ImGui C bindings (vendor/imgui/imgui_shim.h). Single @cImport shared by
// the renderer (backends) and input (event feed), re-exported as rhodo.imgui.
pub const imgui = @cImport({
    @cInclude("imgui_shim.h");
});
