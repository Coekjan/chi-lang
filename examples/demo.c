#include <stdio.h>

int main() {
    __chi_hook__(end) {
        printf("Hello, world!\n");
    };
end:
    return 0;
}
