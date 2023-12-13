#include <stdio.h>

int main() {
    FILE *file1 = fopen("files/file1.txt", "r");
    printf("opened file: %p\n", file1);

    __chi_hook__(ret) {
        fclose(file1);
        printf("closed file: %p\n", file1);
    };

    FILE *file2 = fopen("files/file2.txt", "r");
    printf("opened file: %p\n", file2);

    __chi_hook__(ret) {
        fclose(file2);
        printf("closed file: %p\n", file2);
    };

    char buf[128] = {0};
    
    fgets(buf, sizeof buf - 1, file1);
    printf("read from file: %p\n", file1);
    printf("content: %s\n", buf);

    fgets(buf, sizeof buf - 1, file2);
    printf("read from file: %p\n", file2);
    printf("content: %s\n", buf);
ret:
    return 0;
}
