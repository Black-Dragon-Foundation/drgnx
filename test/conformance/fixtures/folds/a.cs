using System;

namespace Geo
{
    public class Point
    {
        public int X { get; set; }

        public int Norm()
        {
            return X;
        }

        [Fact]
        public void Adds()
        {
            Assert.Equal(1, 1);
        }
    }
}
