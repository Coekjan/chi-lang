#include <errno.h>
#include <pthread.h>
#include <stdio.h>

#define MUTEX_NUM 32
#define PTHREAD_NUM 16

pthread_mutex_t mtx[MUTEX_NUM];
pthread_t thread[PTHREAD_NUM];

int access_index(int child_index, int array_index) {
    return child_index % 2 == 0 ? array_index : MUTEX_NUM - array_index - 1;
}

void *race(void *arg) {
    const int index = (int)arg;
    int i;

    __chi_hook__ (retry) {
        for (; i >= 0; i--)
            pthread_mutex_unlock(&mtx[access_index(index, i)]);
    };
    __chi_hook__ (ret) {
        for (i = 0; i < MUTEX_NUM; i++)
            pthread_mutex_unlock(&mtx[access_index(index, i)]);
    };
    while (1) {
        for (i = 0; i < MUTEX_NUM; i++)
            if (pthread_mutex_trylock(&mtx[access_index(index, i)]) == EBUSY)
                goto retry;
        break;
retry:
    }
    printf("thread %d (tid=%lu) acquired all mutexes\n", index, pthread_self());
ret:
    return NULL;
}

int main() {
    int i;
    
    for (i = 0; i < MUTEX_NUM; i++)
        pthread_mutex_init(&mtx[i], NULL);
    __chi_hook__ (ret) {
        for (i = 0; i < MUTEX_NUM; i++)
            pthread_mutex_destroy(&mtx[i]);
    };
    for (i = 0; i < PTHREAD_NUM; i++)
        pthread_create(&thread[i], NULL, race, (void *)i);
    for (i = 0; i < PTHREAD_NUM; i++) {
        pthread_join(thread[i], NULL);
        printf("child %d (tid=%lu) exited\n", i, thread[i]);
    }
ret:
    return 0;
}