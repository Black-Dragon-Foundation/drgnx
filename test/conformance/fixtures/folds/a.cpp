#include <vector>

namespace geo {

class Point {
 public:
  int norm () const
  {
    return x + y;
  }
  int x, y;
};

}  // namespace geo

int main ()
{
  auto f = [] (int a) {
    return a * 2;
  };
  return f (1);
}
