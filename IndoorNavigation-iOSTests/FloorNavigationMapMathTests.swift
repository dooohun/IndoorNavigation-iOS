import CoreGraphics
import Testing
@testable import IndoorNavigation_iOS

struct FloorNavigationMapMathTests {
    @Test("route bearing does not switch before the current segment changes")
    func routeBearingDoesNotSwitchBeforeCurrentSegmentChanges() {
        let route = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 8)
        ]

        let firstBearing = FloorNavigationMapMath.routeBearingDegrees(
            routePoints: route,
            currentPoint: CGPoint(x: 2, y: 0.2)
        )
        let nextBearing = FloorNavigationMapMath.routeBearingDegrees(
            routePoints: route,
            currentPoint: CGPoint(x: 9.3, y: 0.1)
        )

        #expect(abs((firstBearing ?? -999) - 0) < 0.001)
        #expect(abs((nextBearing ?? -999) - 0) < 0.001)
    }

    @Test("polygon dominant axis ignores a kinked route edge inside the same polygon")
    func polygonDominantAxisIgnoresKinkedRouteEdge() {
        let corridor = [
            CGPoint(x: 0, y: -1),
            CGPoint(x: 14, y: -1),
            CGPoint(x: 14, y: 1),
            CGPoint(x: 7, y: 1.2),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 0, y: -1)
        ]
        let route = [
            CGPoint(x: 1, y: 0),
            CGPoint(x: 8, y: 0),
            CGPoint(x: 8, y: 0.9)
        ]

        let routeBearing = FloorNavigationMapMath.routeBearingDegrees(
            routePoints: route,
            currentPoint: CGPoint(x: 8, y: 0.7)
        )
        let axis = FloorNavigationMapMath.dominantAxisDegrees(rings: [corridor])
        let mapBearing = axis.map {
            FloorNavigationMapMath.orientedAxisDegrees(axisDegrees: $0, referenceDegrees: routeBearing)
        }

        #expect(abs((routeBearing ?? -999) - 90) < 0.001)
        #expect(abs((mapBearing ?? -999) - 0) < 3.0)
    }

    @Test("polygon dominant axis follows long polygon edges")
    func polygonDominantAxisFollowsLongPolygonEdges() {
        let corridor = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 16, y: 0),
            CGPoint(x: 16, y: 2),
            CGPoint(x: 9, y: 2.4),
            CGPoint(x: 0, y: 2),
            CGPoint(x: 0, y: 0)
        ]

        let axis = FloorNavigationMapMath.dominantAxisDegrees(rings: [corridor])

        #expect(abs((axis ?? -999) - 0) < 1.0)
    }

    @Test("user display point projects to route edge")
    func userDisplayPointProjectsToRouteEdge() {
        let route = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 12, y: 0)
        ]

        let projected = FloorNavigationMapMath.projectedPointOnRoute(
            routePoints: route,
            currentPoint: CGPoint(x: 5, y: 1.7)
        )

        #expect(abs((projected?.x ?? -999) - 5) < 0.001)
        #expect(abs((projected?.y ?? -999) - 0) < 0.001)
    }

    @Test("virtual route start projects to its connected graph edge")
    func virtualRouteStartProjectsToConnectedGraphEdge() {
        let segments = [
            FloorNavigationMapMath.GraphSegment(
                fromId: "a",
                toId: "b",
                type: "corridor",
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 10, y: 0)
            ),
            FloorNavigationMapMath.GraphSegment(
                fromId: "b",
                toId: "c",
                type: "corridor",
                start: CGPoint(x: 10, y: 0),
                end: CGPoint(x: 10, y: 8)
            )
        ]

        let projected = FloorNavigationMapMath.projectedPointOnGraphEdge(
            point: CGPoint(x: 5, y: 2.2),
            segments: segments,
            preferredConnectedNodeId: "b"
        )

        #expect(abs((projected?.x ?? -999) - 5) < 0.001)
        #expect(abs((projected?.y ?? -999) - 0) < 0.001)
    }

    @Test("remaining distance starts from projection on current route segment")
    func remainingDistanceStartsFromProjectionOnCurrentRouteSegment() {
        let route = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 5)
        ]

        let remaining = FloorNavigationMapMath.remainingDistanceOnRoute(
            routePoints: route,
            currentPoint: CGPoint(x: 4, y: 2)
        )

        #expect(abs((remaining ?? -999) - 11) < 0.001)
    }

    @Test("lateral width uses route bearing perpendicular span")
    func lateralWidthUsesRouteBearingPerpendicularSpan() {
        let corridor = [
            CGPoint(x: 0, y: -1.5),
            CGPoint(x: 12, y: -1.5),
            CGPoint(x: 12, y: 1.5),
            CGPoint(x: 0, y: 1.5)
        ]

        let width = FloorNavigationMapMath.lateralWidthMeters(
            rings: [corridor],
            bearingDegrees: 0
        )

        #expect(abs((width ?? -999) - 3) < 0.001)
    }

    @Test("current point outside polygon is projected to the polygon boundary")
    func outsidePointProjectsToPolygonBoundary() {
        let ring = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 10),
            CGPoint(x: 0, y: 10)
        ]

        let inside = FloorNavigationMapMath.constrainedPoint(
            CGPoint(x: 4, y: 5),
            polygonRings: [ring],
            bounds: nil
        )
        let outside = FloorNavigationMapMath.constrainedPoint(
            CGPoint(x: 12, y: 5),
            polygonRings: [ring],
            bounds: nil
        )

        #expect(inside == CGPoint(x: 4, y: 5))
        #expect(abs(outside.x - 10) < 0.001)
        #expect(abs(outside.y - 5) < 0.001)
    }
}
