import 'package:test/test.dart';
import 'package:voxcraft/voxcraft.dart';

void main() {
  group('TechTreeSolver & ProductionQueue', () {
    test('enforces prerequisites, accumulates research speed bonus & executes batch recipes', () {
      final tech = TechTreeSolver()
        ..addNode(const TechNodeDef(
          id: 'smelting_1',
          name: 'Refined Smelting',
          researchCosts: {'ore': 2.0},
          researchTimeSeconds: 2.0,
          bonus: TechBonusEffect(
            recipeSpeedBonus: 0.5,
            byproductYieldBonus: 0.25,
            unlockedRecipeIds: ['steel_ingot'],
          ),
        ))
        ..addNode(const TechNodeDef(
          id: 'smelting_2',
          name: 'Alloy Arc',
          prerequisites: ['smelting_1'],
          researchTimeSeconds: 1.5,
          bonus: TechBonusEffect(recipeSpeedBonus: 0.5),
        ));

      expect(tech.hasCycle(), isFalse);
      expect(tech.isAvailable('smelting_2'), isFalse);

      final pool = {'ore': 10.0};
      expect(tech.startResearch('smelting_1', resourcePool: pool), isTrue);
      expect(pool['ore'], closeTo(8.0, 1e-6));
      expect(tech.stepResearch(2.1), 'smelting_1');
      expect(tech.isAvailable('smelting_2'), isTrue);
      expect(tech.totalSpeedMultiplier, closeTo(1.5, 1e-6));

      const ironRecipe = FactoryRecipe(
        id: 'iron_ingot',
        name: 'Iron Ingot',
        inputs: [CraftResourceAmount('ore', 2.0)],
        outputs: [CraftResourceAmount('iron', 1.0)],
        byproducts: [CraftResourceAmount('slag', 1.0)],
        craftDurationSeconds: 1.5,
      );
      final recipes = {'iron_ingot': ironRecipe};

      final queue = ProductionQueue(maxActiveSlots: 1)
        ..deposit('ore', 6.0)
        ..enqueue(ironRecipe, batches: 3, techTree: tech);

      // Speed is 1.5x, so 1.0s real time completes 1 batch (1.5s craft time).
      final done1 = queue.step(1.0, recipes: recipes, techTree: tech);
      expect(done1, 1);
      expect(queue.amountOf('iron'), closeTo(1.0, 1e-6));
      expect(queue.amountOf('slag'), closeTo(1.25, 1e-6)); // +25% tech byproduct bonus

      queue.step(2.5, recipes: recipes, techTree: tech);
      expect(queue.totalCompletedBatches, 3);
      expect(queue.amountOf('iron'), closeTo(3.0, 1e-6));
    });
  });

  group('ConveyorNetwork', () {
    test('routes packets fairly through round-robin splitter onto belts with throughput caps', () {
      final net = ConveyorNetwork()
        ..addNode(ConveyorNode(id: 'src', kind: ConveyorNodeKind.producer))
        ..addNode(ConveyorNode(id: 'split', kind: ConveyorNodeKind.splitter))
        ..addNode(ConveyorNode(id: 'dstA', kind: ConveyorNodeKind.consumer))
        ..addNode(ConveyorNode(id: 'dstB', kind: ConveyorNodeKind.consumer));

      net.connect(id: 'feed', fromNodeId: 'src', toNodeId: 'split', itemsPerSecond: 10.0, lengthMeters: 1.0, beltSpeedMps: 5.0);
      net.connect(id: 'left', fromNodeId: 'split', toNodeId: 'dstA', itemsPerSecond: 5.0, lengthMeters: 1.0, beltSpeedMps: 5.0);
      net.connect(id: 'right', fromNodeId: 'split', toNodeId: 'dstB', itemsPerSecond: 5.0, lengthMeters: 1.0, beltSpeedMps: 5.0);

      net.nodes['src']!.deposit('iron', 12.0);
      for (var i = 0; i < 60; i++) {
        net.tick(0.1);
      }

      expect(net.nodes['dstA']!.amountOf('iron'), greaterThanOrEqualTo(4.0));
      expect(net.nodes['dstB']!.amountOf('iron'), greaterThanOrEqualTo(4.0));
      expect(net.totalDelivered, greaterThanOrEqualTo(18));
    });
  });

  group('DynamicMarketBook', () {
    test('adjusts prices up on scarcity buy, down on surplus sell & reverts toward equilibrium', () {
      final market = DynamicMarketBook()
        ..registerCommodity(
          const MarketCommoditySpec(
            id: 'steel',
            name: 'Steel Ingot',
            basePrice: 100.0,
            equilibriumStock: 100.0,
            elasticity: 0.7,
            meanReversionRate: 0.5,
          ),
        );

      final initial = market.priceOf('steel');
      expect(initial, closeTo(100.0, 1e-4));

      final bought = market.buy('steel', 50.0);
      expect(bought.quantityExecuted, closeTo(50.0, 1e-4));
      final scarcePrice = market.priceOf('steel');
      expect(scarcePrice, greaterThan(initial));

      final sold = market.sell('steel', 120.0);
      expect(sold.quantityExecuted, closeTo(120.0, 1e-4));
      expect(market.priceOf('steel'), lessThan(initial));

      for (var i = 0; i < 40; i++) {
        market.tick(0.25);
      }
      expect(market.priceOf('steel'), closeTo(100.0, 4.0));
    });
  });
}
