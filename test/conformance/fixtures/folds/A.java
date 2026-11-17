import java.util.List;

/* A block comment
   over two lines. */
public class A {
    int norm(int x,
             int y) {
        return x + y;
    }

    @Test
    void adds() {
        assert norm(1, 1) == 2;
    }
}
