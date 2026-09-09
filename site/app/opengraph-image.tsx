import { ImageResponse } from "next/og";

export const alt = "Shrunk — Catch shrinkflation before checkout";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

const RED = "#E24B4A";

export default function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          padding: "80px 96px",
          backgroundColor: "#09090b",
          backgroundImage:
            "radial-gradient(ellipse 80% 60% at 15% -10%, rgba(226,75,74,0.28), transparent), radial-gradient(ellipse 60% 50% at 100% 100%, rgba(226,75,74,0.12), transparent)",
          fontFamily: "system-ui, -apple-system, sans-serif",
        }}
      >
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 14,
            marginBottom: 40,
          }}
        >
          <ScannedDeltaMark />
          <div style={{ display: "flex", fontSize: 32, fontWeight: 700, color: "#fafafa" }}>
            Shrunk
          </div>
        </div>
        <div
          style={{
            display: "flex",
            fontSize: 68,
            fontWeight: 800,
            lineHeight: 1.08,
            color: "#fafafa",
            maxWidth: 980,
          }}
        >
          Catch shrinkflation before checkout
        </div>
        <div
          style={{
            display: "flex",
            marginTop: 28,
            fontSize: 30,
            color: "#a1a1aa",
            maxWidth: 880,
          }}
        >
          Check documented size changes, available current pricing, and better-value alternatives.
        </div>
        <div
          style={{
            display: "flex",
            marginTop: 48,
            alignItems: "center",
            gap: 12,
            fontSize: 24,
            color: "#fafafa",
            fontWeight: 600,
          }}
        >
          <div
            style={{
              display: "flex",
              padding: "8px 20px",
              borderRadius: 999,
              backgroundColor: "rgba(255,255,255,0.08)",
              color: "#fafafa",
            }}
          >
            Free to scan
          </div>
          <div
            style={{
              display: "flex",
              padding: "8px 20px",
              borderRadius: 999,
              backgroundColor: "rgba(255,255,255,0.08)",
              color: "#fafafa",
            }}
          >
            No brand pays us
          </div>
        </div>
      </div>
    ),
    { ...size }
  );
}

function ScannedDeltaMark() {
  const bars = [28, 23, 18, 13, 9];
  const corner = {
    position: "absolute" as const,
    width: 16,
    height: 16,
    borderColor: "#fffaf3",
    borderStyle: "solid",
  };

  return (
    <div
      style={{
        position: "relative",
        display: "flex",
        width: 64,
        height: 64,
        flexShrink: 0,
        borderRadius: 16,
        backgroundColor: RED,
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <div style={{ ...corner, left: 10, top: 10, borderWidth: "4px 0 0 4px", borderRadius: "7px 0 0 0" }} />
      <div style={{ ...corner, right: 10, top: 10, borderWidth: "4px 4px 0 0", borderRadius: "0 7px 0 0" }} />
      <div style={{ ...corner, left: 10, bottom: 10, borderWidth: "0 0 4px 4px", borderRadius: "0 0 0 7px" }} />
      <div style={{ ...corner, right: 10, bottom: 10, borderWidth: "0 4px 4px 0", borderRadius: "0 0 7px 0" }} />
      <div style={{ display: "flex", height: 30, alignItems: "flex-end", gap: 3 }}>
        {bars.map((height) => (
          <div key={height} style={{ width: 4, height, borderRadius: 2, backgroundColor: "#fffaf3" }} />
        ))}
      </div>
    </div>
  );
}
