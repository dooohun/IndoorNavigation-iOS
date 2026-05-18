import UIKit

/// 2D 경로 지도(FloorNavigationMapView) 전용 디자인 토큰.
/// Wanted 디자인시스템 Light 테마 고정. raw color 직접 사용 금지 — 이 파일만 수정하여 색 변경.
/// 다른 화면(currentStepCard, scanningOverlay 등)에는 적용하지 않는다.
enum MapDesignTokens {

    // MARK: - Surface

    enum Surface {
        /// Background.Elevated.Normal -> Light: #ffffff, Dark: #212225
        static let floorFill = UIColor.white
        /// Background.Normal.Alternative -> Light: #f7f7f8, Dark: #0f0f10
        static let backdropDim = UIColor(red: 247 / 255, green: 247 / 255, blue: 248 / 255, alpha: 1)
        /// Background.Elevated.Normal -> Light: #ffffff, Dark: #212225
        static let labelChip = UIColor.white
        /// Background.Elevated.Normal -> Light: #ffffff, Dark: #212225
        static let controlFill = UIColor.white
        /// Fill.Strong -> Light: #70737c29, Dark: #70737c47
        static let grabber = UIColor(red: 112 / 255, green: 115 / 255, blue: 124 / 255, alpha: 0.16)
    }

    // MARK: - Stroke

    enum Stroke {
        /// Line.Solid.Normal -> Light: #e1e2e4, Dark: #37383c
        static let floorOutline = UIColor(red: 225 / 255, green: 226 / 255, blue: 228 / 255, alpha: 1)
        /// Line.Solid._Strong -> Light: #aeb0b6, Dark: #70737c
        static let edgeCorridor = UIColor(red: 174 / 255, green: 176 / 255, blue: 182 / 255, alpha: 1)
        /// Line.Normal.Normal -> Light: #70737c38, Dark: #70737c52
        static let edgeOther = UIColor(red: 112 / 255, green: 115 / 255, blue: 124 / 255, alpha: 0.22)
        /// Primary.Strong -> Light: #005eeb, Dark: #1a75ff
        static let routeHalo = UIColor(red: 0, green: 94 / 255, blue: 235 / 255, alpha: 1)
        /// Background.Elevated.Normal -> Light: #ffffff, Dark: #212225
        static let markerHalo = UIColor.white
        /// Line.Normal.Normal -> Light: #70737c38, Dark: #70737c52
        static let labelBorder = UIColor(red: 112 / 255, green: 115 / 255, blue: 124 / 255, alpha: 0.22)
    }

    // MARK: - Text

    enum Text {
        /// Label.Strong -> Light: #000000, Dark: #ffffff
        static let primary = UIColor.black
        /// Label.Normal -> Light: #171719, Dark: #f7f7f8
        static let onChip = UIColor(red: 23 / 255, green: 23 / 255, blue: 25 / 255, alpha: 1)
        /// Static.White -> Light: #ffffff, Dark: #ffffff
        static let onAccent = UIColor.white
    }

    // MARK: - Accent

    enum Accent {
        /// Primary.Normal -> Light: #0066ff, Dark: #3385ff
        static let route = UIColor(red: 0, green: 102 / 255, blue: 1, alpha: 1)
        /// Primary.Normal -> Light: #0066ff, Dark: #3385ff
        static let currentPosition = UIColor(red: 0, green: 102 / 255, blue: 1, alpha: 1)
        /// Accent.Foreground.Orange -> Light: #d17600, Dark: #ff9200
        static let poi = UIColor(red: 209 / 255, green: 118 / 255, blue: 0, alpha: 1)
        /// Accent.Foreground.Cyan -> Light: #0098b2, Dark: #00bdde
        static let elevator = UIColor(red: 0, green: 152 / 255, blue: 178 / 255, alpha: 1)
        /// Accent.Foreground.Violet -> Light: #5b37ed, Dark: #9e86fc
        static let stairs = UIColor(red: 91 / 255, green: 55 / 255, blue: 237 / 255, alpha: 1)
        /// Accent.Foreground.Green -> Light: #009632, Dark: #1ed45a
        static let escalator = UIColor(red: 0, green: 150 / 255, blue: 50 / 255, alpha: 1)
    }

    // MARK: - Shadow

    enum Shadow {
        static let route = UIColor(white: 0.0, alpha: 0.12)
        static let marker = UIColor(white: 0.0, alpha: 0.14)
        static let positionHalo = UIColor(white: 0.0, alpha: 0.18)
        static let positionArrow = UIColor(white: 0.0, alpha: 0.20)
        /// 아이콘 기반 마커용 약화 그림자 (기존 marker 0.14 → 0.10).
        static let markerIcon = UIColor(white: 0.0, alpha: 0.10)
    }

    // MARK: - Metric

    enum Metric {
        /// 지도 컨테이너 높이 비율 (safe area 기준 1/3) — ADR §A
        static let containerHeightRatio: CGFloat = 1.0 / 3.0
        /// 픽셀/미터 기준 짧은 변에 보이는 미터 수 — ADR §B
        static let metersPerScreenShortSide: CGFloat = 16.0
        /// corridor polygon 폭을 계산할 수 없을 때만 쓰는 fallback 표시 반경.
        static let fallbackVisibleRadiusMeters: CGFloat = 1.5
        /// 가장 넓은 현재 복도 폭이 지도 가로의 절반 정도로 보이게 하는 기준 비율.
        static let corridorWidthScreenRatio: CGFloat = 0.5
        /// 사용자가 조절할 수 있는 2D 지도 확대 배율 범위.
        static let mapZoomMinimum: Float = 0.7
        static let mapZoomDefault: Float = 1.0
        static let mapZoomMaximum: Float = 5.0
        /// localNavScale 상한 multiplier (floorFitScale 대비) — ADR §B
        static let scaleUpperBoundMultiplier: CGFloat = 3.5
        /// localNavScale 하한 multiplier (floorFitScale 대비) — ADR §B
        static let scaleLowerBoundMultiplier: CGFloat = 0.95
        /// heading 보간 시정수 τ (s) — ADR §D, EMA α=0.2 와 조합
        static let headingSmoothingTau: CFTimeInterval = 0.18
        /// corridor polygon 전환 시 지도 회전 보간 시정수 τ (s)
        static let mapBearingSmoothingTau: CFTimeInterval = 0.32
        /// AR pose → 2D 표시 위치 보간 시정수 τ (s)
        static let mapPositionSmoothingTau: CFTimeInterval = 0.16
        /// 현재 위치 바로 아래 route stroke가 마커 밑에서 끊기지 않도록 남기는 clip 여유.
        static let routeClipOverlap: CGFloat = 2.0
        /// 하단 2D 지도 sheet 상단 radius — Frame/Xlarge.Radius.
        static let containerTopCornerRadius: CGFloat = 20
        /// 현재 위치 puck 지름.
        static let positionPuckDiameter: CGFloat = 34
        /// POI/층간연결 marker bubble 높이.
        static let markerBubbleHeight: CGFloat = 28
        /// 2D 지도 마커 SVG 아이콘 한 변 크기 (정사각).
        static let markerIconSize: CGFloat = 18
        /// 마커 아이콘과 하단 라벨 사이 세로 간격.
        static let markerLabelGap: CGFloat = 1
        /// 마커 라벨 폰트 크기 (room POI 전용).
        static let markerLabelFontSize: CGFloat = 8
    }
}
