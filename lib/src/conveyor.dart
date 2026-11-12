import 'dart:math' as math;

/// Functional role of a node in a [ConveyorNetwork].
enum ConveyorNodeKind {
  producer,
  storage,
  splitter,
  merger,
  consumer,
}

/// Packet moving along a [ConveyorLane].
final class ConveyorPacket {
  final String resourceId;
  final double amount;
  double remainingMeters;

  ConveyorPacket({
    required this.resourceId,
    required this.amount,
    required this.remainingMeters,
  });
}

/// Endpoint node storing or routing items inside a [ConveyorNetwork].
final class ConveyorNode {
  final String id;
  final ConveyorNodeKind kind;
  final int maxStorageUnits;
  final Map<String, double> inventory = {};
  int roundRobinCursor = 0;

  ConveyorNode({
    required this.id,
    this.kind = ConveyorNodeKind.storage,
    this.maxStorageUnits = 100,
  });

  double amountOf(String resourceId) => inventory[resourceId] ?? 0.0;

  double get totalStoredUnits {
    var sum = 0.0;
    for (final v in inventory.values) {
      sum += v;
    }
    return sum;
  }

  void deposit(String resourceId, double amount) {
    if (amount <= 0.0) return;
    inventory[resourceId] = (inventory[resourceId] ?? 0.0) + amount;
  }

  String? _firstAvailableResource(String? filter) {
    if (filter != null) {
      return (inventory[filter] ?? 0.0) >= 1.0 - 1e-6 ? filter : null;
    }
    for (final e in inventory.entries) {
      if (e.value >= 1.0 - 1e-6) return e.key;
    }
    return null;
  }

  bool _withdrawOne(String resourceId) {
    final avail = inventory[resourceId] ?? 0.0;
    if (avail + 1e-6 < 1.0) return false;
    final rem = avail - 1.0;
    if (rem <= 1e-7) {
      inventory.remove(resourceId);
    } else {
      inventory[resourceId] = rem;
    }
    return true;
  }
}

/// Directed throughput-capped conveyor belt linking two [ConveyorNode]s.
final class ConveyorLane {
  final String id;
  final String fromNodeId;
  final String toNodeId;
  final double itemsPerSecond;
  final double lengthMeters;
  final double beltSpeedMps;
  final int capacity;
  final String? filterResourceId;

  final List<ConveyorPacket> packets = [];
  double dispatchCooldown = 0.0;

  ConveyorLane({
    required this.id,
    required this.fromNodeId,
    required this.toNodeId,
    this.itemsPerSecond = 2.0,
    this.lengthMeters = 4.0,
    this.beltSpeedMps = 2.0,
    this.capacity = 12,
    this.filterResourceId,
  });
}

/// Simulates factory item transport belts, round-robin splitters, and mergers.
final class ConveyorNetwork {
  final Map<String, ConveyorNode> _nodes = {};
  final List<ConveyorLane> _lanes = [];
  final Map<String, List<ConveyorLane>> _outgoing = {};

  int _totalDelivered = 0;

  Map<String, ConveyorNode> get nodes => Map.unmodifiable(_nodes);
  List<ConveyorLane> get lanes => List.unmodifiable(_lanes);
  int get totalDelivered => _totalDelivered;

  void addNode(ConveyorNode node) {
    _nodes[node.id] = node;
    _outgoing.putIfAbsent(node.id, () => []);
  }

  ConveyorLane connect({
    required String id,
    required String fromNodeId,
    required String toNodeId,
    double itemsPerSecond = 2.0,
    double lengthMeters = 4.0,
    double beltSpeedMps = 2.0,
    int capacity = 12,
    String? filterResourceId,
  }) {
    if (!_nodes.containsKey(fromNodeId) || !_nodes.containsKey(toNodeId)) {
      throw ArgumentError('Both conveyor endpoints must be registered nodes.');
    }
    final lane = ConveyorLane(
      id: id,
      fromNodeId: fromNodeId,
      toNodeId: toNodeId,
      itemsPerSecond: itemsPerSecond,
      lengthMeters: lengthMeters,
      beltSpeedMps: beltSpeedMps,
      capacity: capacity,
      filterResourceId: filterResourceId,
    );
    _lanes.add(lane);
    _outgoing[fromNodeId]!.add(lane);
    return lane;
  }

  /// Advances belt dispatch and packet travel by [dt] seconds, returning newly delivered item count.
  int tick(double dt) {
    if (dt <= 0.0) return 0;
    var deliveredThisTick = 0;

    // 1. Move in-transit items and deliver into target node buffers.
    for (final lane in _lanes) {
      if (lane.dispatchCooldown > 0.0) {
        lane.dispatchCooldown = math.max(0.0, lane.dispatchCooldown - dt);
      }
      final target = _nodes[lane.toNodeId]!;
      final travel = lane.beltSpeedMps * dt;
      for (var i = lane.packets.length - 1; i >= 0; i--) {
        final pkt = lane.packets[i];
        pkt.remainingMeters -= travel;
        if (pkt.remainingMeters <= 1e-6 &&
            target.totalStoredUnits + pkt.amount <= target.maxStorageUnits + 1e-6) {
          target.deposit(pkt.resourceId, pkt.amount);
          lane.packets.removeAt(i);
          deliveredThisTick++;
          _totalDelivered++;
        }
      }
    }

    // 2. Dispatch ready items from source nodes with round-robin splitter fairness.
    for (final node in _nodes.values) {
      if (node.kind == ConveyorNodeKind.consumer) continue;
      final outs = _outgoing[node.id];
      if (outs == null || outs.isEmpty) continue;

      final len = outs.length;
      var tried = 0;
      while (tried < len) {
        final idx = (node.roundRobinCursor + tried) % len;
        final lane = outs[idx];
        tried++;
        if (lane.dispatchCooldown > 1e-6 || lane.packets.length >= lane.capacity) {
          continue;
        }
        final resId = node._firstAvailableResource(lane.filterResourceId);
        if (resId == null) continue;
        if (node._withdrawOne(resId)) {
          lane.packets.add(
            ConveyorPacket(
              resourceId: resId,
              amount: 1.0,
              remainingMeters: lane.lengthMeters,
            ),
          );
          lane.dispatchCooldown =
              lane.itemsPerSecond > 1e-6 ? 1.0 / lane.itemsPerSecond : 0.0;
          if (node.kind == ConveyorNodeKind.splitter) {
            node.roundRobinCursor = (idx + 1) % len;
          }
          break;
        }
      }
    }

    return deliveredThisTick;
  }
}
