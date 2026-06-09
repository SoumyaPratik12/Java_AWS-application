FROM mcr.microsoft.com/openjdk/jdk:21-ubuntu
RUN groupadd -r appgroup && useradd -r -g appgroup appuser
WORKDIR /app
COPY target/order-service-1.0.0.jar app.jar
RUN chown appuser:appgroup app.jar
USER appuser
EXPOSE 8082
ENTRYPOINT ["java", \
  "-XX:+UseContainerSupport", \
  "-XX:MaxRAMPercentage=75.0", \
  "-jar", "app.jar"]
