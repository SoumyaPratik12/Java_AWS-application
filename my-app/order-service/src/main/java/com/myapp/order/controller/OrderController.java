package com.myapp.order.controller;

import com.myapp.shared.dto.ApiResponse;
import com.myapp.order.model.Order;
import com.myapp.order.service.OrderService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/v1/orders")
public class OrderController {

    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = orderService;
    }

    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "ok", "service", "order-service"));
    }

    @GetMapping
    public ResponseEntity<ApiResponse<List<Order>>> getOrders() {
        return ResponseEntity.ok(ApiResponse.ok(orderService.getAllOrders()));
    }
}
