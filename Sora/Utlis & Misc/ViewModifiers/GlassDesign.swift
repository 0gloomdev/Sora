//
//  GlassDesign.swift
//  Sora
//
//  Personalización por Gloom_dev.
//
//  Liquid Glass de Apple (iOS 26+) aplicado únicamente a la capa de
//  navegación —tab bar y controles flotantes—, según las Human Interface
//  Guidelines: con moderación, variantes regular/clear y respeto total a
//  los ajustes de accesibilidad (Reducir Transparencia desactiva el vidrio).
//

import SwiftUI

/// Tema de material para la capa de navegación de Sora.
enum GlassTheme: String, CaseIterable, Identifiable {
    /// Automático: Liquid Glass en iOS 26+, material clásico antes.
    case system
    /// Liquid Glass regular (legible sobre cualquier fondo).
    case regular
    /// Liquid Glass clear (máxima visibilidad del contenido, ideal sobre multimedia).
    case clear
    /// Material clásico siempre (ultraThinMaterial, sin vidrio).
    case classic

    var id: String { rawValue }
}

/// Aplica Liquid Glass en iOS 26+ según el tema elegido, con respaldo a
/// materiales clásicos en iOS 15–25 y cuando Reducir Transparencia está activo.
struct AdaptiveGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let theme: GlassTheme
    let shape: S
    let fallback: Material

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, *) {
                if reduceTransparency || theme == .classic {
                    content.background(fallback, in: shape)
                } else if theme == .clear {
                    content.glassEffect(.clear, in: shape)
                } else {
                    content.glassEffect(.regular, in: shape)
                }
            } else {
                content.background(fallback, in: shape)
            }
        }
    }
}

extension View {
    /// Vidrio adaptativo para la capa de navegación (HIG: solo controles flotantes).
    func adaptiveGlass<S: Shape>(
        _ theme: GlassTheme,
        in shape: S,
        fallback: Material = .ultraThinMaterial
    ) -> some View {
        modifier(AdaptiveGlass(theme: theme, shape: shape, fallback: fallback))
    }

    /// Agrupa los elementos con vidrio cercanos para compartir la región de
    /// muestreo (rendimiento + unidad visual). Transparente en iOS <26 o tema clásico.
    func glassCluster(enabled: Bool) -> some View {
        modifier(GlassCluster(enabled: enabled))
    }
}

/// Contenedor compartido de Liquid Glass (HIG: combinar efectos cercanos).
/// En iOS <26 o con `enabled == false` no altera la jerarquía visual.
struct GlassCluster: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, *), enabled {
                GlassEffectContainer {
                    content
                }
            } else {
                content
            }
        }
    }
}
