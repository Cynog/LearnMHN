# by Kevin Rupp, Stefan Vocht

"""
This part of the package contains functions related to (differentiated) uniformization as well as functions
to compute the log-likelihood score and its gradient for datasets that contain samples with known ages

(see Rupp et al.(2021): 'Differentiated uniformization: A new method for inferring Markov chains on combinatorial state spaces including stochastic epidemic models')
"""

cimport cython

from scipy.linalg.cython_blas cimport dcopy, dscal, daxpy, ddot, dnrm2
from libc.stdlib cimport malloc, free
from libc.math cimport exp, log

from mhn.ssr.state_storage cimport State, StateAgeStorage
from mhn.ssr.state_space_restriction cimport get_mutation_num, restricted_q_vec, restricted_q_diag

import numpy as np
cimport numpy as np

np.import_array()


@cython.wraparound(False)
@cython.boundscheck(False)
cdef void restricted_derivative_ik(double[:, :] theta_mat, int i, double[:] x_vec, State *state, int mutation_num, int k,
                                double *pout) nogil:
    """
    This function multiplies the kronecker product for the partial derivative of Q wrt to theta_ik with a vector

    :param theta_mat: matrix containing the theta entries
    :param i: vector is multiplied with the ith kronecker product (ith summand in eq. 9 of the original paper)
    :param x_vec: vector that is multiplied with the kronecker product
    :param state: current state used to compute the gradient
    :param mutation_num: number of mutations present in state
    :param k: column index of derivative
    :param pout: vector which will contain the result of this multiplication
    """

    # initialize some constants used in this function
    cdef double[:] theta_i = theta_mat[i, :]
    cdef int n = theta_i.shape[0]
    cdef int nx = 1 << mutation_num
    cdef int nxhalf = nx / 2
    cdef double mOne = -1
    cdef double zero = 0

    cdef int incx = 1
    cdef int incx2 = 2
    cdef int j

    # if we have no diagonal and the ith gene is not mutated, the result is always a zero vector
    #if not diag and not (state[0].parts[i >> 5] >> (i & 31)) & 1:
    #    dscal(&nx, &zero, pout, &incx)
    #    return

    cdef double *ptmp = <double *> malloc(nx * sizeof(double))
    cdef double *px1
    cdef double *px2
    cdef double *shuffled_vec
    cdef double *old_vec
    cdef double *swap_vec
    cdef double theta

    # for the shuffle algorithm we have to initialize the pointers correctly
    if mutation_num & 1 == 1:
        swap_vec = ptmp
        shuffled_vec = pout
    else:
        swap_vec = pout
        shuffled_vec = ptmp

    old_vec = &x_vec[0]

    cdef int state_copy = state[0].parts[0]

    # use the shuffle algorithm to compute the product of the kronecker product with a vector
    for j in range(n):
        if state_copy & 1:
            dcopy(&nxhalf, old_vec, &incx2, shuffled_vec, &incx)
            dcopy(&nxhalf, old_vec+1, &incx2, shuffled_vec+nxhalf, &incx)

            theta = exp(theta_i[j])
            px1 = shuffled_vec
            px2 = shuffled_vec + nxhalf
            # this function is only needed for the dua where we never have to transpose Q' or delete the diagonal
            if j == i:
                dcopy(&nxhalf, px1, &incx, px2, &incx)
                dscal(&nxhalf, &theta, px2, &incx)
                dcopy(&nxhalf, px2, &incx, px1, &incx)
                dscal(&nxhalf, &mOne, px1, &incx)

            else:
                dscal(&nxhalf, &theta, px2, &incx)
                if j == k:
                    dscal(&nxhalf, &zero, px1, &incx)

            old_vec = shuffled_vec
            shuffled_vec = swap_vec
            swap_vec = old_vec

        elif i == j:
            theta = -exp(theta_i[j])

            # if old_vec is still pointing to x_vec, we have to change it to not alter x_vec
            if old_vec == &x_vec[0]:
                dcopy(&nx, old_vec, &incx, swap_vec, &incx)
                old_vec = swap_vec

            dscal(&nx, &theta, old_vec, &incx)

		# if the mutation state of the next gene is stored on the current state_copy, make a bit shift to the right
		# else state_copy becomes the next integer stored in the given state (x >> 5  <=> x // 32, x & 31 <=> x % 32)
        if (j + 1) & 31:
            state_copy >>= 1
        else:
            state_copy = state[0].parts[(j+1) >> 5]

    free(ptmp)

@cython.wraparound(False)
@cython.boundscheck(False)
cdef void restricted_derivative_ik_diag(double[:, :] theta_mat, int i, State *state, int mutation_num, int k,
                                double *pout):
    """
    This function calculates the diagonal of dQ/d theta_ik

    :param theta_mat: matrix containing the theta entries
    :param i: vector is multiplied with the ith kronecker product (ith summand in eq. 9 of the original paper)
    :param state: current state used to compute the gradient
    :param mutation_num: number of mutations present in state
    :param k: column index of derivative
    :param pout: vector which will contain the result of this multiplication
    """

    # initialize some constants used in this function
    cdef double[:] theta_i = theta_mat[i, :]
    cdef int n = theta_i.shape[0]
    cdef int nx = 1 << mutation_num
    cdef int nxhalf = nx / 2
    cdef double mOne = -1
    cdef double zero = 0

    cdef int incx = 1
    cdef int incx2 = 2
    cdef int j

    # if we have no diagonal and the ith gene is not mutated, the result is always a zero vector
    #if not diag and not (state[0].parts[i >> 5] >> (i & 31)) & 1:
    #    dscal(&nx, &zero, pout, &incx)
    #    return

    cdef double *ptmp = <double *> malloc(nx * sizeof(double))
    cdef double *px1
    cdef double *px2
    cdef double *shuffled_vec
    cdef double *old_vec
    cdef double *swap_vec
    cdef double theta
    cdef double[:] x_vec = np.ones(nx, dtype=np.double)

    # for the shuffle algorithm we have to initialize the pointers correctly
    if mutation_num & 1 == 1:
        swap_vec = ptmp
        shuffled_vec = pout
    else:
        swap_vec = pout
        shuffled_vec = ptmp

    old_vec = &x_vec[0]

    cdef int state_copy = state[0].parts[0]

    # use the shuffle algorithm to compute the product of the kronecker product with a vector
    for j in range(n):
        if state_copy & 1:
            dcopy(&nxhalf, old_vec, &incx2, shuffled_vec, &incx)
            dcopy(&nxhalf, old_vec+1, &incx2, shuffled_vec+nxhalf, &incx)

            theta = exp(theta_i[j])
            px1 = shuffled_vec
            px2 = shuffled_vec + nxhalf
            # this function is only needed for the dua where we never have to transpose dQ or remove its diagonal
            if j == i:
                dcopy(&nxhalf, px1, &incx, px2, &incx)
                dscal(&nxhalf, &theta, px2, &incx)
                dcopy(&nxhalf, px2, &incx, px1, &incx)
                dscal(&nxhalf, &mOne, px1, &incx)
                dscal(&nxhalf, &zero, px2, &incx)

            else:
                dscal(&nxhalf, &theta, px2, &incx)
                if j == k:
                    dscal(&nxhalf, &zero, px1, &incx)

            old_vec = shuffled_vec
            shuffled_vec = swap_vec
            swap_vec = old_vec

        elif i == j:
            theta = -exp(theta_i[j])

            # if old_vec is still pointing to x_vec, we have to change it to not alter x_vec
            if old_vec == &x_vec[0]:
                dcopy(&nx, old_vec, &incx, swap_vec, &incx)
                old_vec = swap_vec

            dscal(&nx, &theta, old_vec, &incx)

		# if the mutation state of the next gene is stored on the current state_copy, make a bit shift to the right
		# else state_copy becomes the next integer stored in the given state (x >> 5  <=> x // 32, x & 31 <=> x % 32)
        if (j + 1) & 31:
            state_copy >>= 1
        else:
            state_copy = state[0].parts[(j+1) >> 5]

    free(ptmp)


@cython.wraparound(False)
@cython.boundscheck(False)
cdef double[:] restricted_expm(double[:, :] theta, double[:] b, State *state, double t, double eps):
    """
    this functions multiplies expm(tQ) with a vector b

    :param theta: matrix containing the theta entries
    :param b: array that is multiplied with expm(tQ)
    :param state: state representing current tumor sample
    :param t: age of state
    :param eps: accuracy
    """
    cdef int mutation_num = get_mutation_num(state)
    cdef int nx = 1 << mutation_num
    cdef int i_one = 1

    # Compute the diagonal of Q
    cdef double *dg = <double *> malloc(nx * sizeof(double))
    restricted_q_diag(theta, state, dg)
    # Calculate the L2-norm of the diagonal to use as scaling constant gamma
    cdef double gam =  dnrm2(&nx, dg, &i_one)
    cdef double gam_inv = 1/gam

    cdef double[:] pt = np.zeros(nx, dtype=np.double)
    cdef int n = 0
    cdef double w = 1.0
    cdef double egtw
    cdef double *q_vec_result = <double *> malloc(nx * sizeof(double))
    cdef double[:] q = b.copy()

    while eps > (1 - np.sum(pt)):
        egtw = exp(-1.0*gam*t)*w
        daxpy(&nx, &egtw, &q[0], &i_one, &pt[0], &i_one)
        n += 1
        # Calculate q = [1/gamma*Q+I]b
        restricted_q_vec(theta, q, state, q_vec_result, diag=True, transp=False) # q=1/gamma*Qb
        daxpy(&nx, &gam_inv, q_vec_result, &i_one, &q[0], &i_one) # calculate q=q+Ib
        w *= gam*t/n

    free(dg)
    free(q_vec_result)
    return pt


@cython.wraparound(False)
@cython.boundscheck(False)
cdef double calc_gamma(double[:, :] theta, State *state, int i, int k):
    """
    this function calculates the derivative of the scaling factor gamma wrt. theta_ik
    :param theta: matrix containing the theta entries
    :param state: state representing current tumor sample
    :param i: row index of theta entry to take derivative wrt.
    :param k: column index of theta entry to take derivative wrt.
    """
    cdef int mutation_num = get_mutation_num(state)
    cdef int nx = 1 << mutation_num
    cdef int one = 1
    cdef double *deriv_q_diag = <double *> malloc(nx * sizeof(double))
    restricted_derivative_ik_diag(theta, i, state, mutation_num, k, deriv_q_diag)
    cdef double *q_diag = <double*> malloc(nx*sizeof(double))
    restricted_q_diag(theta, state, q_diag)
    cdef double num = ddot(&nx, deriv_q_diag, &one, q_diag, &one)
    cdef double denom = dnrm2(&nx, q_diag, &one)
    return denom, num / denom


@cython.wraparound(False)
@cython.boundscheck(False)
cdef void dua(double[:, :] theta, double[:] b, State *state, double t, int i, int k, double eps, double[:] pt, double[:] dp):
    """
    Computes the frechet derivative of expm(tQ)b using the DUA Algorithm
    :param theta: matrix containing the theta entries
    :param b: distribution to be multiplied from the right
    :param state: state representing the current tumor sample
    :param t: Age of tumor, amount of time to be projected in the future
    :param i: row index of theta to take the derivative wrt.
    :param k: column index of theta to take the derivative wrt.
    :param eps: accuracy
    :param pt: container to store the resulting pt
    :param dp: container to store the derivative wrt. theta_ik
    """
    cdef int mutation_num = get_mutation_num(state)
    cdef int nx = 1 << mutation_num

    cdef double w = 1.0
    cdef int n = 0 # Iteration number
    cdef int one = 1
    cdef double gfac = 1.0
    pt = np.zeros(nx, dtype=np.double)
    dp = np.zeros(nx, dtype=np.double)
    cdef double[:] q = b.copy()
    cdef double[:] dq = np.zeros(nx, dtype=np.double)
    cdef double * temp = <double *> malloc(nx * sizeof(double))
    cdef double * temp2 = <double *> malloc(nx * sizeof(double))

    cdef double gamma, dgamma
    gamma, dgamma = calc_gamma(theta, state, i, k)
    cdef double dgam_inv = -1.0*1/gamma**2*dgamma
    cdef double gam_inv = 1/gamma
    cdef double ewg = exp(-1.0*gamma*t)*w
    while eps > (1 - np.sum(pt)):
        # pt = pt + exp(-gam*t)q
        daxpy(&nx, &ewg, &q[0], &one, &pt[0], &one)
        # dpt = dpt + exp(-gamma*t)w dq
        daxpy(&nx, &ewg, &dq[0], &one, &dp[0], &one)
        # dpt = dpt + exp(-gamma*t)w dgamma(n/gamma-t)q
        gfac = ewg*dgamma*(n/gamma-t)
        daxpy(&nx, &gfac, &q[0], &one, &dp[0], &one)

        n += 1
        # dq = -1/gamma^2*dg*Q q + 1/gamma*dQ q
        restricted_q_vec(theta, q, state, temp, True, False)
        dscal(&nx, &dgam_inv, temp, &one)
        restricted_derivative_ik_diag(theta, i, state, mutation_num, k, temp2)
        daxpy(&nx, &gam_inv, temp2, &one, temp, &one) # temp2 isn't needed anymore and its allocated memory can be reused

        # dq = dq + [1/gamma*Q+I]dq
        restricted_q_vec(theta, dq, state, temp2, True, False)
        daxpy(&nx, &gam_inv, temp2, &one, &dq[0], &one)
        for j in range(nx):
            dq[j] += temp[j]+temp2[j]

        # q = [1/gamma*Q + I]q
        restricted_q_vec(theta, q, state, temp, True, False)
        daxpy(&nx, &gam_inv, temp, &one, &q[0], &one)

        w *= gamma*t/n

    free(temp)
    free(temp2)
