var out = {
  screens: workspace.screens.map(function (s) {
    return { name: s.name, manufacturer: s.manufacturer, model: s.model, serialNumber: s.serialNumber,
             geometry: { x: s.geometry.x, y: s.geometry.y, width: s.geometry.width, height: s.geometry.height } };
  }),
  windows: workspace.windowList().map(function (w) {
    return { pid: w.pid, caption: w.caption, output: w.output ? w.output.name : null, fullScreen: w.fullScreen,
             normalWindow: w.normalWindow, resourceClass: w.resourceClass, internalId: String(w.internalId),
             geometry: { x: w.frameGeometry.x, y: w.frameGeometry.y, width: w.frameGeometry.width, height: w.frameGeometry.height },
             active: workspace.activeWindow === w };
  })
};
callDBus("org.drgnx.Probe", "/probe", "org.drgnx.Probe", "Report", JSON.stringify(out));
