package com.myapp.notification.service;

import org.springframework.stereotype.Service;
import java.util.List;
import java.util.Map;

@Service
public class NotificationService {

    public List<Map<String, Object>> getAllNotifications() {
        return List.of(
            Map.of("id", 1, "userId", 1, "type", "EMAIL", "message", "Your order has been shipped", "read", false),
            Map.of("id", 2, "userId", 2, "type", "SMS", "message", "Payment confirmed for ORD-2024-002", "read", true)
        );
    }
}
