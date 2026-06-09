package com.myapp.user.service;

import com.myapp.user.model.User;
import org.springframework.stereotype.Service;
import java.util.List;

@Service
public class UserService {

    public List<User> getAllUsers() {
        return List.of(
            new User(1L, "Alice Johnson", "alice@myapp.com", "ADMIN"),
            new User(2L, "Bob Smith", "bob@myapp.com", "USER")
        );
    }
}
