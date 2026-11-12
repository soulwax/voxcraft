import 'dart:math' as math;

/// Economic parameters defining a tradable resource inside [DynamicMarketBook].
final class MarketCommoditySpec {
  final String id;
  final String name;
  final double basePrice;
  final double minPrice;
  final double maxPrice;
  final double equilibriumStock;
  final double elasticity;
  final double meanReversionRate;

  const MarketCommoditySpec({
    required this.id,
    required this.name,
    required this.basePrice,
    double? minPrice,
    double? maxPrice,
    this.equilibriumStock = 100.0,
    this.elasticity = 0.65,
    this.meanReversionRate = 0.08,
  })  : minPrice = minPrice ?? (basePrice * 0.25),
        maxPrice = maxPrice ?? (basePrice * 4.0);
}

/// Live supply/price snapshot of a commodity.
final class MarketCommodityState {
  final MarketCommoditySpec spec;
  double currentStock;
  double currentPrice;
  double rollingAveragePrice;
  final List<double> priceHistory = [];

  MarketCommodityState({
    required this.spec,
    double? initialStock,
  })  : currentStock = initialStock ?? spec.equilibriumStock,
        currentPrice = spec.basePrice,
        rollingAveragePrice = spec.basePrice {
    priceHistory.add(currentPrice);
  }
}

/// Result returned when executing a market buy or sell order.
final class MarketTradeReceipt {
  final String commodityId;
  final double quantityExecuted;
  final double totalValue;
  final double averageUnitPrice;
  final double postTradePrice;

  const MarketTradeReceipt({
    required this.commodityId,
    required this.quantityExecuted,
    required this.totalValue,
    required this.averageUnitPrice,
    required this.postTradePrice,
  });
}

/// Supply/demand elastic commodity market with rolling moving-average history & equilibrium reversion.
final class DynamicMarketBook {
  final Map<String, MarketCommodityState> _listings = {};
  final int maxHistorySamples;

  DynamicMarketBook({this.maxHistorySamples = 32});

  Map<String, MarketCommodityState> get listings => Map.unmodifiable(_listings);

  void registerCommodity(MarketCommoditySpec spec, {double? initialStock}) {
    final state = MarketCommodityState(spec: spec, initialStock: initialStock);
    _recomputePrice(state);
    _listings[spec.id] = state;
  }

  double priceOf(String commodityId) => _listings[commodityId]?.currentPrice ?? 0.0;
  double stockOf(String commodityId) => _listings[commodityId]?.currentStock ?? 0.0;

  void _recomputePrice(MarketCommodityState st) {
    final s = st.spec;
    final ratio = s.equilibriumStock / math.max(1.0, st.currentStock);
    final raw = s.basePrice * math.pow(ratio, s.elasticity).toDouble();
    st.currentPrice = raw.clamp(s.minPrice, s.maxPrice);
  }

  void _recordHistory(MarketCommodityState st) {
    st.rollingAveragePrice = st.rollingAveragePrice * 0.8 + st.currentPrice * 0.2;
    st.priceHistory.add(st.currentPrice);
    if (st.priceHistory.length > maxHistorySamples) {
      st.priceHistory.removeAt(0);
    }
  }

  /// Purchases [quantity] units from market supply, increasing spot price via scarcity elasticity.
  MarketTradeReceipt buy(String commodityId, double quantity) {
    final st = _listings[commodityId];
    if (st == null || quantity <= 0.0 || st.currentStock <= 0.0) {
      return MarketTradeReceipt(
        commodityId: commodityId,
        quantityExecuted: 0.0,
        totalValue: 0.0,
        averageUnitPrice: st?.currentPrice ?? 0.0,
        postTradePrice: st?.currentPrice ?? 0.0,
      );
    }

    final executed = math.min(quantity, st.currentStock);
    final prePrice = st.currentPrice;
    st.currentStock = math.max(0.0, st.currentStock - executed);
    _recomputePrice(st);
    _recordHistory(st);
    final avgUnit = (prePrice + st.currentPrice) * 0.5;
    return MarketTradeReceipt(
      commodityId: commodityId,
      quantityExecuted: executed,
      totalValue: executed * avgUnit,
      averageUnitPrice: avgUnit,
      postTradePrice: st.currentPrice,
    );
  }

  /// Sells [quantity] units into market supply, lowering spot price via surplus elasticity.
  MarketTradeReceipt sell(String commodityId, double quantity) {
    final st = _listings[commodityId];
    if (st == null || quantity <= 0.0) {
      return MarketTradeReceipt(
        commodityId: commodityId,
        quantityExecuted: 0.0,
        totalValue: 0.0,
        averageUnitPrice: st?.currentPrice ?? 0.0,
        postTradePrice: st?.currentPrice ?? 0.0,
      );
    }

    final prePrice = st.currentPrice;
    st.currentStock += quantity;
    _recomputePrice(st);
    _recordHistory(st);
    final avgUnit = (prePrice + st.currentPrice) * 0.5;
    return MarketTradeReceipt(
      commodityId: commodityId,
      quantityExecuted: quantity,
      totalValue: quantity * avgUnit,
      averageUnitPrice: avgUnit,
      postTradePrice: st.currentPrice,
    );
  }

  /// Gently relaxes all market stock levels back toward equilibrium over [dt] seconds.
  void tick(double dt) {
    if (dt <= 0.0) return;
    for (final st in _listings.values) {
      final rate = math.min(1.0, st.spec.meanReversionRate * dt);
      st.currentStock += (st.spec.equilibriumStock - st.currentStock) * rate;
      _recomputePrice(st);
      _recordHistory(st);
    }
  }
}
