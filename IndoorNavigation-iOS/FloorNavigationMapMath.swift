import CoreGraphics
import Foundation

enum FloorNavigationMapMath {
    struct GraphSegment {
        let fromId: String
        let toId: String
        let type: String
        let start: CGPoint
        let end: CGPoint
    }

    static func routeBearingDegrees(routePoints: [CGPoint], currentPoint: CGPoint) -> Float? {
        guard routePoints.count >= 2 else { return nil }

        var best: (index: Int, t: CGFloat, distanceSquared: CGFloat)?
        for index in 0..<(routePoints.count - 1) {
            let start = routePoints[index]
            let end = routePoints[index + 1]
            let projected = project(currentPoint, ontoSegmentFrom: start, to: end)
            let distanceSquared = squaredDistance(currentPoint, projected.point)
            if best == nil || distanceSquared < best!.distanceSquared {
                best = (index, projected.t, distanceSquared)
            }
        }

        guard let segmentIndex = best?.index else { return nil }

        for index in segmentIndex..<(routePoints.count - 1) {
            let dx = routePoints[index + 1].x - routePoints[index].x
            let dy = routePoints[index + 1].y - routePoints[index].y
            guard hypot(dx, dy) > 0.001 else { continue }
            return Float(atan2(dy, dx) * 180 / .pi)
        }
        return nil
    }

    static func projectedPointOnRoute(routePoints: [CGPoint], currentPoint: CGPoint) -> CGPoint? {
        guard routePoints.count >= 2 else { return nil }

        var bestPoint: CGPoint?
        var bestDistanceSquared = CGFloat.greatestFiniteMagnitude
        for index in 0..<(routePoints.count - 1) {
            let projected = project(currentPoint, ontoSegmentFrom: routePoints[index], to: routePoints[index + 1]).point
            let distanceSquared = squaredDistance(currentPoint, projected)
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                bestPoint = projected
            }
        }
        return bestPoint
    }

    static func projectedPointOnGraphEdge(point: CGPoint,
                                          segments: [GraphSegment],
                                          preferredConnectedNodeId: String?) -> CGPoint? {
        guard !segments.isEmpty else { return nil }

        let connectedSegments: [GraphSegment]
        if let preferredConnectedNodeId {
            connectedSegments = segments.filter {
                $0.fromId == preferredConnectedNodeId || $0.toId == preferredConnectedNodeId
            }
        } else {
            connectedSegments = []
        }

        let nodeFilteredSegments = connectedSegments.isEmpty ? segments : connectedSegments
        let corridorSegments = nodeFilteredSegments.filter { $0.type.lowercased() == "corridor" }
        let candidates = corridorSegments.isEmpty ? nodeFilteredSegments : corridorSegments

        var bestPoint: CGPoint?
        var bestDistanceSquared = CGFloat.greatestFiniteMagnitude
        for segment in candidates {
            let projected = project(point, ontoSegmentFrom: segment.start, to: segment.end).point
            let distanceSquared = squaredDistance(point, projected)
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                bestPoint = projected
            }
        }
        return bestPoint
    }

    static func remainingDistanceOnRoute(routePoints: [CGPoint], currentPoint: CGPoint) -> CGFloat? {
        guard routePoints.count >= 2 else { return nil }

        var best: (index: Int, t: CGFloat, projected: CGPoint, distanceSquared: CGFloat)?
        for index in 0..<(routePoints.count - 1) {
            let projected = project(currentPoint, ontoSegmentFrom: routePoints[index], to: routePoints[index + 1])
            let distanceSquared = squaredDistance(currentPoint, projected.point)
            if best == nil || distanceSquared < best!.distanceSquared {
                best = (index, projected.t, projected.point, distanceSquared)
            }
        }
        guard let best else { return nil }

        let segmentEnd = routePoints[best.index + 1]
        var remaining = hypot(segmentEnd.x - best.projected.x, segmentEnd.y - best.projected.y)
        if best.index + 1 < routePoints.count - 1 {
            for index in (best.index + 1)..<(routePoints.count - 1) {
                remaining += hypot(routePoints[index + 1].x - routePoints[index].x,
                                   routePoints[index + 1].y - routePoints[index].y)
            }
        }
        return remaining
    }

    static func lateralWidthMeters(rings: [[CGPoint]], bearingDegrees: Float) -> CGFloat? {
        let bearingRadians = CGFloat(bearingDegrees) * .pi / 180
        let right = CGPoint(x: sin(bearingRadians), y: -cos(bearingRadians))
        var widest = CGFloat.zero

        for ring in rings where !ring.isEmpty {
            var minProjection = CGFloat.greatestFiniteMagnitude
            var maxProjection = -CGFloat.greatestFiniteMagnitude
            for point in ring {
                let projection = point.x * right.x + point.y * right.y
                minProjection = min(minProjection, projection)
                maxProjection = max(maxProjection, projection)
            }
            let width = maxProjection - minProjection
            if width.isFinite {
                widest = max(widest, width)
            }
        }

        return widest > 0.001 ? widest : nil
    }

    static func dominantAxisDegrees(rings: [[CGPoint]]) -> Float? {
        var sumX = CGFloat.zero
        var sumY = CGFloat.zero
        var totalWeight = CGFloat.zero

        for ring in rings where ring.count >= 2 {
            for index in 0..<ring.count {
                let start = ring[index]
                let end = ring[(index + 1) % ring.count]
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = hypot(dx, dy)
                guard length > 0.001,
                      dx.isFinite,
                      dy.isFinite else { continue }
                let theta = atan2(dy, dx)
                let weight = length * length
                sumX += cos(2 * theta) * weight
                sumY += sin(2 * theta) * weight
                totalWeight += weight
            }
        }
        guard totalWeight > 0.000001,
              hypot(sumX, sumY) > 0.000001 else { return nil }

        let radians = 0.5 * atan2(sumY, sumX)
        return normalizeAxialDegrees(Float(radians * 180 / .pi))
    }

    static func orientedAxisDegrees(axisDegrees: Float, referenceDegrees: Float?) -> Float {
        let axis = normalizeAxialDegrees(axisDegrees)
        guard let referenceDegrees else { return normalizeDegrees(axis) }

        let opposite = axis + 180
        let axisDelta = abs(shortestArcDelta(from: axis, to: referenceDegrees))
        let oppositeDelta = abs(shortestArcDelta(from: opposite, to: referenceDegrees))
        return normalizeDegrees(oppositeDelta < axisDelta ? opposite : axis)
    }

    static func constrainedPoint(_ point: CGPoint,
                                 polygonRings: [[CGPoint]],
                                 bounds: FloorMapBounds?) -> CGPoint {
        let rings = polygonRings.filter { $0.count >= 3 }
        if !rings.isEmpty {
            if rings.contains(where: { contains(point, in: $0) }) {
                return point
            }
            if let projected = nearestPointOnRings(point, rings: rings) {
                return projected
            }
        }

        guard let bounds else { return point }
        return CGPoint(
            x: min(max(point.x, CGFloat(bounds.minX)), CGFloat(bounds.maxX)),
            y: min(max(point.y, CGFloat(bounds.minY)), CGFloat(bounds.maxY))
        )
    }

    static func contains(_ point: CGPoint, in ring: [CGPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var isInside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let pi = ring[i]
            let pj = ring[j]
            let intersects = ((pi.y > point.y) != (pj.y > point.y))
                && (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x)
            if intersects {
                isInside.toggle()
            }
            j = i
        }
        return isInside
    }

    private static func nearestPointOnRings(_ point: CGPoint, rings: [[CGPoint]]) -> CGPoint? {
        var bestPoint: CGPoint?
        var bestDistanceSquared = CGFloat.greatestFiniteMagnitude

        for ring in rings where ring.count >= 2 {
            for index in 0..<ring.count {
                let start = ring[index]
                let end = ring[(index + 1) % ring.count]
                let projected = project(point, ontoSegmentFrom: start, to: end).point
                let distanceSquared = squaredDistance(point, projected)
                if distanceSquared < bestDistanceSquared {
                    bestDistanceSquared = distanceSquared
                    bestPoint = projected
                }
            }
        }

        return bestPoint
    }

    private static func project(_ point: CGPoint,
                                ontoSegmentFrom start: CGPoint,
                                to end: CGPoint) -> (point: CGPoint, t: CGFloat) {
        let vx = end.x - start.x
        let vy = end.y - start.y
        let lenSquared = vx * vx + vy * vy
        guard lenSquared > 0.000001 else { return (start, 0) }
        let rawT = ((point.x - start.x) * vx + (point.y - start.y) * vy) / lenSquared
        let t = min(max(rawT, 0), 1)
        return (
            CGPoint(x: start.x + vx * t, y: start.y + vy * t),
            t
        )
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func normalizeDegrees(_ value: Float) -> Float {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result
    }

    private static func normalizeAxialDegrees(_ value: Float) -> Float {
        var result = value.truncatingRemainder(dividingBy: 180)
        if result < 0 { result += 180 }
        return result
    }

    private static func shortestArcDelta(from current: Float, to target: Float) -> Float {
        var delta = target - current
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }
}
