import 'dart:collection';
import 'dart:math' as math;

/// Modifiers granted when a [TechNodeDef] completes research.
final class TechBonusEffect {
  final double recipeSpeedBonus;
  final double byproductYieldBonus;
  final double powerSavings01;
  final List<String> unlockedRecipeIds;

  const TechBonusEffect({
    this.recipeSpeedBonus = 0.0,
    this.byproductYieldBonus = 0.0,
    this.powerSavings01 = 0.0,
    this.unlockedRecipeIds = const [],
  });
}

/// Research node in a directed acyclic technology graph.
final class TechNodeDef {
  final String id;
  final String name;
  final List<String> prerequisites;
  final Map<String, double> researchCosts;
  final double researchTimeSeconds;
  final TechBonusEffect bonus;

  const TechNodeDef({
    required this.id,
    required this.name,
    this.prerequisites = const [],
    this.researchCosts = const {},
    this.researchTimeSeconds = 5.0,
    this.bonus = const TechBonusEffect(),
  });
}

/// Solves research prerequisites, active research progress, and cumulative tech modifiers.
final class TechTreeSolver {
  final Map<String, TechNodeDef> _nodes = {};
  final Set<String> _unlocked = {};
  final Set<String> _unlockedRecipes = {};

  String? _activeResearchId;
  double _activeProgressSeconds = 0.0;

  Map<String, TechNodeDef> get nodes => Map.unmodifiable(_nodes);
  Set<String> get unlockedIds => Set.unmodifiable(_unlocked);
  String? get activeResearchId => _activeResearchId;
  double get activeProgressSeconds => _activeProgressSeconds;

  double get activeProgress01 {
    final id = _activeResearchId;
    if (id == null) return 0.0;
    final def = _nodes[id];
    if (def == null || def.researchTimeSeconds <= 1e-6) return 1.0;
    return (_activeProgressSeconds / def.researchTimeSeconds).clamp(0.0, 1.0);
  }

  void addNode(TechNodeDef node) {
    _nodes[node.id] = node;
  }

  bool isUnlocked(String techId) => _unlocked.contains(techId);

  bool isAvailable(String techId) {
    final def = _nodes[techId];
    if (def == null || _unlocked.contains(techId)) return false;
    for (final pre in def.prerequisites) {
      if (!_unlocked.contains(pre)) return false;
    }
    return true;
  }

  bool isRecipeUnlocked(String recipeId, {String? requiredTechId}) {
    if (requiredTechId == null) return true;
    return _unlocked.contains(requiredTechId) || _unlockedRecipes.contains(recipeId);
  }

  /// Checks whether registered prerequisites form any cycle via Kahn's algorithm.
  bool hasCycle() {
    final inDegree = <String, int>{for (final id in _nodes.keys) id: 0};
    final dependents = <String, List<String>>{};
    for (final node in _nodes.values) {
      for (final pre in node.prerequisites) {
        if (!_nodes.containsKey(pre)) continue;
        inDegree[node.id] = (inDegree[node.id] ?? 0) + 1;
        dependents.putIfAbsent(pre, () => []).add(node.id);
      }
    }
    final q = Queue<String>();
    for (final entry in inDegree.entries) {
      if (entry.value == 0) q.add(entry.key);
    }
    var visited = 0;
    while (q.isNotEmpty) {
      final curr = q.removeFirst();
      visited++;
      for (final dep in dependents[curr] ?? const <String>[]) {
        final next = (inDegree[dep] ?? 1) - 1;
        inDegree[dep] = next;
        if (next == 0) q.add(dep);
      }
    }
    return visited != _nodes.length;
  }

  double get totalSpeedMultiplier {
    var mult = 1.0;
    for (final id in _unlocked) {
      final def = _nodes[id];
      if (def != null) mult += def.bonus.recipeSpeedBonus;
    }
    return math.max(0.1, mult);
  }

  double get totalByproductBonus {
    var bonus = 0.0;
    for (final id in _unlocked) {
      final def = _nodes[id];
      if (def != null) bonus += def.bonus.byproductYieldBonus;
    }
    return math.max(0.0, bonus);
  }

  double get totalPowerScale {
    var savings = 0.0;
    for (final id in _unlocked) {
      final def = _nodes[id];
      if (def != null) savings += def.bonus.powerSavings01;
    }
    return (1.0 - savings).clamp(0.15, 2.0);
  }

  bool startResearch(String techId, {Map<String, double>? resourcePool}) {
    if (!isAvailable(techId) || _activeResearchId != null) return false;
    final def = _nodes[techId]!;
    if (resourcePool != null) {
      for (final entry in def.researchCosts.entries) {
        if ((resourcePool[entry.key] ?? 0.0) + 1e-6 < entry.value) {
          return false;
        }
      }
      for (final entry in def.researchCosts.entries) {
        resourcePool[entry.key] =
            math.max(0.0, (resourcePool[entry.key] ?? 0.0) - entry.value);
      }
    }
    _activeResearchId = techId;
    _activeProgressSeconds = 0.0;
    return true;
  }

  /// Advances active research progress and returns the completed tech ID if finished this step.
  String? stepResearch(double dt) {
    final id = _activeResearchId;
    if (id == null || dt <= 0.0) return null;
    final def = _nodes[id];
    if (def == null) {
      _activeResearchId = null;
      return null;
    }
    _activeProgressSeconds += dt;
    if (_activeProgressSeconds + 1e-6 >= def.researchTimeSeconds) {
      unlockImmediate(id);
      _activeResearchId = null;
      _activeProgressSeconds = 0.0;
      return id;
    }
    return null;
  }

  void unlockImmediate(String techId) {
    final def = _nodes[techId];
    if (def == null) return;
    _unlocked.add(techId);
    _unlockedRecipes.addAll(def.bonus.unlockedRecipeIds);
  }
}
