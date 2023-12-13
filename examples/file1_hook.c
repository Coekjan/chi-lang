#include <stdio.h>

int main() {
    FILE *file = fopen("files/file1.txt", "r");
    printf("opened file: %p\n", file);

    __chi_hook__(ret) {
        fclose(file);
        printf("closed file: %p\n", file);
    };

    char buf[128] = {0};
    fgets(buf, sizeof buf - 1, file);
    printf("read from file: %p\n", file);
    printf("content: %s\n", buf);
ret:
    return 0;
}
