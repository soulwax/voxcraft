import 'dart:math' as math;

import 'tech_tree.dart';

/// Resource identifier and quantity tuple for recipes and factory inventories.
final class CraftResourceAmount {
  final String resourceId;
  final double amount;

  const CraftResourceAmount(this.resourceId, this.amount);
}

/// Multi-input, multi-output transformation recipe with optional byproduct yields and tech gating.
final class FactoryRecipe {
  final String id;
  final String name;
  final List<CraftResourceAmount> inputs;
  final List<CraftResourceAmount> outputs;
  final List<CraftResourceAmount> byproducts;
  final double craftDurationSeconds;
  final double powerKw;
  final String? requiredTechId;

  const FactoryRecipe({
    required this.id,
    required this.name,
    required this.inputs,
    required this.outputs,
    this.byproducts = const [],
    this.craftDurationSeconds = 2.0,
    this.powerKw = 10.0,
    this.requiredTechId,
  });
}

/// Queued or active production batch inside a [ProductionQueue].
final class ProductionJob {
  final String recipeId;
  int remainingBatches;
  int completedBatches = 0;
  double progressSeconds = 0.0;
  bool consumingBatch = false;
  bool paused;

  ProductionJob({
    required this.recipeId,
    required this.remainingBatches,
    this.paused = false,
  });

  double progress01(double batchDuration) => batchDuration <= 1e-6
      ? 1.0
      : (progressSeconds / batchDuration).clamp(0.0, 1.0);
}

/// Parallel-slot production processor executing [FactoryRecipe]s with tech bonuses and power scaling.
final class ProductionQueue {
  final int maxActiveSlots;
  final Map<String, double> inventory = {};
  final List<ProductionJob> _jobs = [];
  double baseSpeedMultiplier;

  int _totalCompletedBatches = 0;
  double _totalPowerConsumedKwh = 0.0;

  ProductionQueue({
    this.maxActiveSlots = 1,
    this.baseSpeedMultiplier = 1.0,
  });

  List<ProductionJob> get jobs => List.unmodifiable(_jobs);
  int get totalCompletedBatches => _totalCompletedBatches;
  double get totalPowerConsumedKwh => _totalPowerConsumedKwh;

  double amountOf(String resourceId) => inventory[resourceId] ?? 0.0;

  void deposit(String resourceId, double amount) {
    if (amount <= 0.0) return;
    inventory[resourceId] = (inventory[resourceId] ?? 0.0) + amount;
  }

  double withdraw(String resourceId, double amount) {
    if (amount <= 0.0) return 0.0;
    final avail = inventory[resourceId] ?? 0.0;
    final taken = math.min(avail, amount);
    if (taken > 0.0) {
      final rem = avail - taken;
      if (rem <= 1e-9) {
        inventory.remove(resourceId);
      } else {
        inventory[resourceId] = rem;
      }
    }
    return taken;
  }

  bool hasInputs(FactoryRecipe recipe) {
    for (final req in recipe.inputs) {
      if ((inventory[req.resourceId] ?? 0.0) + 1e-6 < req.amount) {
        return false;
      }
    }
    return true;
  }

  bool enqueue(
    FactoryRecipe recipe, {
    int batches = 1,
    TechTreeSolver? techTree,
  }) {
    if (batches <= 0) return false;
    if (techTree != null &&
        !techTree.isRecipeUnlocked(recipe.id, requiredTechId: recipe.requiredTechId)) {
      return false;
    }
    _jobs.add(ProductionJob(recipeId: recipe.id, remainingBatches: batches));
    return true;
  }

  void cancelJobAt(int index) {
    if (index >= 0 && index < _jobs.length) {
      _jobs.removeAt(index);
    }
  }

  /// Advances up to [maxActiveSlots] unpaused jobs by [dt] seconds and returns finished batch count.
  int step(
    double dt, {
    required Map<String, FactoryRecipe> recipes,
    TechTreeSolver? techTree,
    double powerGridScale = 1.0,
  }) {
    if (dt <= 0.0 || _jobs.isEmpty) return 0;
    final speedScale = math.max(0.05, baseSpeedMultiplier) *
        (techTree?.totalSpeedMultiplier ?? 1.0) *
        powerGridScale.clamp(0.0, 4.0);
    final byproductScale = 1.0 + (techTree?.totalByproductBonus ?? 0.0);
    final powerScale = techTree?.totalPowerScale ?? 1.0;

    var finishedThisStep = 0;
    var activeRunners = 0;

    for (var i = 0; i < _jobs.length && activeRunners < math.max(1, maxActiveSlots); i++) {
      final job = _jobs[i];
      if (job.paused || job.remainingBatches <= 0) continue;
      final recipe = recipes[job.recipeId];
      if (recipe == null) continue;
      if (techTree != null &&
          !techTree.isRecipeUnlocked(recipe.id, requiredTechId: recipe.requiredTechId)) {
        continue;
      }

      if (!job.consumingBatch) {
        if (!hasInputs(recipe)) continue;
        for (final req in recipe.inputs) {
          withdraw(req.resourceId, req.amount);
        }
        job.consumingBatch = true;
      }

      activeRunners++;
      final dtEff = dt * speedScale;
      job.progressSeconds += dtEff;
      _totalPowerConsumedKwh += recipe.powerKw * powerScale * (dt / 3600.0);

      final duration = math.max(1e-4, recipe.craftDurationSeconds);
      while (job.consumingBatch && job.progressSeconds + 1e-7 >= duration) {
        job.progressSeconds -= duration;
        for (final out in recipe.outputs) {
          deposit(out.resourceId, out.amount);
        }
        for (final byp in recipe.byproducts) {
          deposit(byp.resourceId, byp.amount * byproductScale);
        }
        job.completedBatches++;
        job.remainingBatches--;
        _totalCompletedBatches++;
        finishedThisStep++;
        job.consumingBatch = false;

        if (job.remainingBatches > 0 && hasInputs(recipe)) {
          for (final req in recipe.inputs) {
            withdraw(req.resourceId, req.amount);
          }
          job.consumingBatch = true;
        } else {
          job.progressSeconds = 0.0;
        }
      }
    }

    _jobs.removeWhere((j) => j.remainingBatches <= 0 && !j.consumingBatch);
    return finishedThisStep;
  }
}
