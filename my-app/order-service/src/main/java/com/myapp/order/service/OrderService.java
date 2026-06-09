package com.myapp.order.service;

import com.myapp.order.model.Order;
import org.springframework.stereotype.Service;
import java.math.BigDecimal;
import java.util.List;

@Service
public class OrderService {

    public List<Order> getAllOrders() {
        return List.of(
            new Order(1L, "ORD-2024-001", 1L, new BigDecimal("149.99"), "DELIVERED"),
            new Order(2L, "ORD-2024-002", 2L, new BigDecimal("89.50"), "PROCESSING")
        );
    }
}
