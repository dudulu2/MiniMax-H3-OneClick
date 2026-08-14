import { app } from "../../../scripts/app.js";

app.registerExtension({
    name: "MiniMaxH3.FirstRunWorkflow",
    async setup() {
        const key = "minimax-h3-workflow-compatibility-minimax_h3_fl2va_pruned_int8_convrot-v3";
        if (localStorage.getItem(key)) return;
        try {
            // Wait until ComfyUI has created the graph before loading subgraphs.
            await new Promise((resolve) => {
                const waitForGraph = () => {
                    if (app.canvas && app.canvas.graph) resolve();
                    else requestAnimationFrame(waitForGraph);
                };
                waitForGraph();
            });
            const path = encodeURIComponent("workflows/MiniMax_H3_compatibility.json");
            const response = await fetch(`/api/userdata/${path}`);
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            const workflow = await response.json();
            await app.loadGraphData(workflow, true, true, "MiniMax_H3_compatibility.json");
            localStorage.setItem(key, "1");
        } catch (error) {
            console.error("MiniMax H3 workflow autoload failed", error);
        }
    }
});

