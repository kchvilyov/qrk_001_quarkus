package qrk_001;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;

@Path("/hello")
public class GreetingResource {
    @GET
    public String hello() {
        return "Hello from Quarkus REST";
    }
}
